-- OT Laundry: atomic invoice payment posting
-- Applied to the connected OT-Laundry Supabase project.
CREATE OR REPLACE FUNCTION public.record_invoice_payment(
  p_invoice_id uuid, p_cash_account_id uuid, p_amount numeric,
  p_payment_method text DEFAULT 'cash', p_reference text DEFAULT NULL,
  p_notes text DEFAULT NULL, p_idempotency_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $$
DECLARE v_uid uuid:=auth.uid(); v_branch uuid; v_total numeric(14,2); v_paid numeric(14,2);
 v_payment_id uuid; v_payment_no bigint; v_balance numeric(14,2);
BEGIN
 IF v_uid IS NULL OR NOT private.user_has_permission('payments.create') THEN RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE='42501'; END IF;
 SELECT branch_id,total_amount INTO v_branch,v_total FROM public.invoices
 WHERE id=p_invoice_id AND branch_id IN (SELECT private.user_branch_ids()) AND status<>'cancelled' FOR UPDATE;
 IF v_branch IS NULL THEN RAISE EXCEPTION 'INVOICE_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF p_amount IS NULL OR p_amount<=0 OR p_amount>999999999 THEN RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE='22023'; END IF;
 IF p_payment_method NOT IN ('cash','card','bank_transfer','wallet','other') THEN RAISE EXCEPTION 'INVALID_PAYMENT_METHOD' USING ERRCODE='22023'; END IF;
 IF p_idempotency_key IS NOT NULL THEN
  SELECT id INTO v_payment_id FROM public.payments WHERE branch_id=v_branch AND idempotency_key=p_idempotency_key;
  IF v_payment_id IS NOT NULL THEN RETURN jsonb_build_object('payment_id',v_payment_id,'duplicate',true); END IF;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cash_accounts WHERE id=p_cash_account_id AND branch_id=v_branch AND is_active=true) THEN RAISE EXCEPTION 'CASH_ACCOUNT_INVALID' USING ERRCODE='22023'; END IF;
 SELECT coalesce(sum(amount),0) INTO v_paid FROM public.payments WHERE invoice_id=p_invoice_id AND payment_status='posted';
 v_balance:=greatest(0,v_total-v_paid);
 IF p_amount>v_balance THEN RAISE EXCEPTION 'PAYMENT_EXCEEDS_BALANCE' USING ERRCODE='22023'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':payments'));
 SELECT coalesce(max(payment_number),0)+1 INTO v_payment_no FROM public.payments WHERE branch_id=v_branch;
 INSERT INTO public.payments(branch_id,invoice_id,cash_account_id,payment_number,amount,payment_method,payment_status,reference_number,idempotency_key,notes,received_by)
 VALUES(v_branch,p_invoice_id,p_cash_account_id,v_payment_no,round(p_amount,2),p_payment_method,'posted',nullif(trim(p_reference),''),p_idempotency_key,nullif(trim(p_notes),''),v_uid)
 RETURNING id INTO v_payment_id;
 INSERT INTO public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,payment_id,reference,description,created_by)
 VALUES(v_branch,p_cash_account_id,'invoice_payment','in',round(p_amount,2),v_payment_id,'PAY-'||v_payment_no,'تحصيل فاتورة #'||p_invoice_id::text,v_uid);
 INSERT INTO public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
 VALUES(v_branch,v_uid,'payment_received','payments',v_payment_id::text,jsonb_build_object('invoice_id',p_invoice_id,'amount',round(p_amount,2),'payment_number',v_payment_no));
 RETURN jsonb_build_object('payment_id',v_payment_id,'payment_number',v_payment_no,'amount',round(p_amount,2),'remaining_balance',v_balance-round(p_amount,2),'duplicate',false);
END; $$;
REVOKE ALL ON FUNCTION public.record_invoice_payment(uuid,uuid,numeric,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_invoice_payment(uuid,uuid,numeric,text,text,text,text) TO authenticated;
DROP POLICY IF EXISTS cash_transactions_insert_payment_policy ON public.cash_transactions;
CREATE POLICY cash_transactions_insert_payment_policy ON public.cash_transactions FOR INSERT TO authenticated
WITH CHECK (branch_id IN (SELECT private.user_branch_ids()) AND private.user_has_permission('payments.create') AND created_by=auth.uid() AND transaction_type='invoice_payment' AND direction='in');
DROP POLICY IF EXISTS audit_logs_insert_payment_policy ON public.audit_logs;
CREATE POLICY audit_logs_insert_payment_policy ON public.audit_logs FOR INSERT TO authenticated
WITH CHECK (branch_id IN (SELECT private.user_branch_ids()) AND actor_user_id=auth.uid() AND private.user_has_permission('payments.create') AND entity_table='payments');
