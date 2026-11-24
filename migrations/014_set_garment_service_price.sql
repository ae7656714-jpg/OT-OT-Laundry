-- Atomically set the current branch price for one garment/service pair.
-- Keeps service_prices as the dated price source and default_price as a safe fallback.
CREATE OR REPLACE FUNCTION public.set_garment_service_price(
  p_garment_service_id uuid,
  p_price numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_branch_id uuid;
  v_price_row_id uuid;
BEGIN
  IF v_user_id IS NULL OR NOT private.user_has_permission('catalog.manage') THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE='42501';
  END IF;
  IF p_price IS NULL OR p_price < 0 OR p_price > 999999999 THEN
    RAISE EXCEPTION 'INVALID_PRICE' USING ERRCODE='22023';
  END IF;

  SELECT gs.branch_id INTO v_branch_id
  FROM public.garment_services gs
  WHERE gs.id = p_garment_service_id
    AND gs.branch_id IN (SELECT private.user_branch_ids())
    AND gs.is_available = true
  FOR UPDATE;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'GARMENT_SERVICE_NOT_FOUND' USING ERRCODE='P0002';
  END IF;

  SELECT sp.id INTO v_price_row_id
  FROM public.service_prices sp
  WHERE sp.branch_id = v_branch_id
    AND sp.garment_service_id = p_garment_service_id
    AND sp.effective_from <= current_date
    AND (sp.effective_to IS NULL OR sp.effective_to >= current_date)
  ORDER BY sp.effective_from DESC
  LIMIT 1
  FOR UPDATE;

  IF v_price_row_id IS NULL THEN
    INSERT INTO public.service_prices(branch_id,garment_service_id,price,effective_from,created_by)
    VALUES(v_branch_id,p_garment_service_id,round(p_price,2),current_date,v_user_id);
  ELSE
    UPDATE public.service_prices SET price=round(p_price,2),created_by=v_user_id
    WHERE id=v_price_row_id;
  END IF;

  UPDATE public.garment_services
  SET default_price=round(p_price,2),updated_at=now()
  WHERE id=p_garment_service_id AND branch_id=v_branch_id;

  RETURN jsonb_build_object(
    'garment_service_id',p_garment_service_id,
    'price',round(p_price,2),
    'effective_from',current_date,
    'branch_id',v_branch_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_garment_service_price(uuid,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_garment_service_price(uuid,numeric) TO authenticated;
