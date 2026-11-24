-- OT Laundry cashier invoice creation v1
-- Authenticated callers only. Prices are resolved server-side from the branch catalog.
CREATE OR REPLACE FUNCTION public.create_laundry_invoice(
  p_customer_name text,
  p_customer_phone text,
  p_items jsonb,
  p_discount_type text DEFAULT 'value',
  p_discount_value numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_branch_id uuid;
  v_customer_id uuid;
  v_customer_name text := coalesce(nullif(trim(p_customer_name), ''), 'عميل نقدي');
  v_invoice_id uuid;
  v_invoice_number bigint;
  v_subtotal numeric(14,2) := 0;
  v_discount numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_item jsonb;
  v_garment_id uuid;
  v_service_id uuid;
  v_qty integer;
  v_garment_name text;
  v_service_name text;
  v_combo_id uuid;
  v_unit_price numeric(14,2);
  v_line_total numeric(14,2);
  v_result jsonb;
  v_existing jsonb;
  v_count integer := 0;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
  IF NOT private.user_has_permission('invoices.create') THEN RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE='42501'; END IF;
  SELECT p.branch_id INTO v_branch_id FROM public.profiles p WHERE p.id=v_user_id AND p.is_active=true;
  IF v_branch_id IS NULL THEN RAISE EXCEPTION 'ACTIVE_BRANCH_REQUIRED' USING ERRCODE='42501'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items)=0 THEN
    RAISE EXCEPTION 'INVOICE_ITEMS_REQUIRED' USING ERRCODE='22023';
  END IF;
  IF p_discount_type NOT IN ('value','percent') OR coalesce(p_discount_value,0)<0
     OR (p_discount_type='percent' AND p_discount_value>100) THEN
    RAISE EXCEPTION 'INVALID_DISCOUNT' USING ERRCODE='22023';
  END IF;
  IF p_idempotency_key IS NOT NULL THEN
    SELECT result INTO v_existing FROM public.idempotency_keys
    WHERE branch_id=v_branch_id AND idempotency_key=p_idempotency_key AND operation='create_invoice';
    IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  END IF;
  IF nullif(trim(p_customer_phone),'') IS NOT NULL THEN
    SELECT id INTO v_customer_id FROM public.customers
    WHERE branch_id=v_branch_id AND phone=trim(p_customer_phone) AND is_active=true
    ORDER BY created_at DESC LIMIT 1;
  END IF;
  IF v_customer_id IS NULL AND v_customer_name <> 'عميل نقدي' THEN
    INSERT INTO public.customers(branch_id,full_name,phone,created_by)
    VALUES(v_branch_id,v_customer_name,nullif(trim(p_customer_phone),''),v_user_id)
    RETURNING id INTO v_customer_id;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_branch_id::text));
  SELECT coalesce(max(invoice_number),0)+1 INTO v_invoice_number FROM public.invoices WHERE branch_id=v_branch_id;
  v_invoice_id := gen_random_uuid();
  INSERT INTO public.invoices(
    id,branch_id,invoice_number,customer_id,customer_name_snapshot,customer_phone_snapshot,status,
    subtotal,discount_type,discount_value,discount_amount,tax_enabled,tax_rate,tax_amount,total_amount,
    notes,created_by,updated_by
  ) VALUES (
    v_invoice_id,v_branch_id,v_invoice_number,v_customer_id,v_customer_name,nullif(trim(p_customer_phone),''),'received',
    0,p_discount_type,coalesce(p_discount_value,0),0,false,0,0,0,nullif(trim(p_notes),''),v_user_id,v_user_id
  );
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_garment_id := nullif(v_item->>'garment_type_id','')::uuid;
    v_service_id := nullif(v_item->>'service_id','')::uuid;
    v_qty := coalesce(nullif(v_item->>'quantity','')::integer,1);
    IF v_garment_id IS NULL OR v_service_id IS NULL OR v_qty<1 OR v_qty>99 THEN
      RAISE EXCEPTION 'INVALID_INVOICE_ITEM' USING ERRCODE='22023';
    END IF;
    SELECT gs.id,gt.name,s.name,coalesce((
      SELECT sp.price FROM public.service_prices sp
      WHERE sp.branch_id=v_branch_id AND sp.garment_service_id=gs.id
        AND sp.effective_from<=current_date AND (sp.effective_to IS NULL OR sp.effective_to>=current_date)
      ORDER BY sp.effective_from DESC LIMIT 1
    ),gs.default_price)
    INTO v_combo_id,v_garment_name,v_service_name,v_unit_price
    FROM public.garment_services gs
    JOIN public.garment_types gt ON gt.id=gs.garment_type_id AND gt.branch_id=v_branch_id AND gt.is_active=true
    JOIN public.services s ON s.id=gs.service_id AND s.branch_id=v_branch_id AND s.is_active=true
    WHERE gs.branch_id=v_branch_id AND gs.garment_type_id=v_garment_id
      AND gs.service_id=v_service_id AND gs.is_available=true;
    IF v_combo_id IS NULL THEN RAISE EXCEPTION 'INVALID_OR_UNAVAILABLE_SERVICE' USING ERRCODE='22023'; END IF;
    v_line_total := round(v_unit_price*v_qty,2);
    v_subtotal := v_subtotal+v_line_total;
    v_count := v_count+1;
    INSERT INTO public.invoice_items(
      branch_id,invoice_id,garment_type_id,garment_name_snapshot,service_id,service_name_snapshot,
      quantity,unit_price,line_discount,line_total,work_status,sort_order
    ) VALUES (
      v_branch_id,v_invoice_id,v_garment_id,v_garment_name,v_service_id,v_service_name,
      v_qty,v_unit_price,0,v_line_total,'pending',v_count
    );
  END LOOP;
  IF p_discount_type='percent' THEN v_discount := round(v_subtotal*coalesce(p_discount_value,0)/100,2);
  ELSE v_discount := least(v_subtotal,coalesce(p_discount_value,0)); END IF;
  v_total := greatest(0,v_subtotal-v_discount);
  UPDATE public.invoices SET subtotal=v_subtotal,discount_amount=v_discount,total_amount=v_total WHERE id=v_invoice_id;
  INSERT INTO public.invoice_status_history(branch_id,invoice_id,old_status,new_status,reason,changed_by)
  VALUES(v_branch_id,v_invoice_id,NULL,'received','إنشاء الفاتورة',v_user_id);
  INSERT INTO public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
  VALUES(v_branch_id,v_user_id,'create','invoices',v_invoice_id::text,
    jsonb_build_object('invoice_number',v_invoice_number,'total_amount',v_total,'items_count',v_count));
  v_result := jsonb_build_object('invoice_id',v_invoice_id,'invoice_number',v_invoice_number,
    'subtotal',v_subtotal,'discount_amount',v_discount,'total_amount',v_total,'items_count',v_count);
  IF p_idempotency_key IS NOT NULL THEN
    INSERT INTO public.idempotency_keys(branch_id,idempotency_key,operation,result)
    VALUES(v_branch_id,p_idempotency_key,'create_invoice',v_result);
  END IF;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_laundry_invoice(text,text,jsonb,text,numeric,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_laundry_invoice(text,text,jsonb,text,numeric,text,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_laundry_invoice(text,text,jsonb,text,numeric,text,text) TO authenticated;
