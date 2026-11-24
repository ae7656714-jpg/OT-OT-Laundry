-- OT Laundry Phase 7: branch-scoped reporting RPC
-- Uses the caller JWT and existing RLS policies; no service-role bypass.
CREATE OR REPLACE FUNCTION public.get_laundry_reports(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path=public,private,pg_temp AS $$
DECLARE v_uid uuid:=auth.uid(); v_branch uuid; v_start timestamptz; v_end timestamptz; v_result jsonb;
BEGIN
 IF v_uid IS NULL OR NOT private.user_has_permission('invoices.view')
  OR NOT private.user_has_permission('payments.view') OR NOT private.user_has_permission('expenses.view') THEN
  RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE='42501';
 END IF;
 IF p_from IS NULL OR p_to IS NULL OR p_to<p_from OR p_to-p_from>366 THEN
  RAISE EXCEPTION 'INVALID_REPORT_RANGE' USING ERRCODE='22023';
 END IF;
 SELECT branch_id INTO v_branch FROM public.profiles WHERE id=v_uid AND is_active=true;
 IF v_branch IS NULL OR NOT (v_branch IN (SELECT private.user_branch_ids())) THEN
  RAISE EXCEPTION 'BRANCH_FORBIDDEN' USING ERRCODE='42501';
 END IF;
 v_start:=p_from::timestamp AT TIME ZONE 'Africa/Cairo';
 v_end:=(p_to+1)::timestamp AT TIME ZONE 'Africa/Cairo';
 WITH period_invoices AS (
  SELECT id,status,total_amount FROM public.invoices WHERE branch_id=v_branch AND received_at>=v_start AND received_at<v_end
 ), period_payments AS (
  SELECT id,amount,paid_at FROM public.payments WHERE branch_id=v_branch AND payment_status='posted' AND paid_at>=v_start AND paid_at<v_end
 ), period_expenses AS (
  SELECT id,expense_number,description,amount,expense_date FROM public.expenses
  WHERE branch_id=v_branch AND approval_status='approved' AND expense_date BETWEEN p_from AND p_to
 ), daily AS (
  SELECT gs.day::date AS day,
   coalesce((SELECT sum(pp.amount) FROM period_payments pp WHERE (pp.paid_at AT TIME ZONE 'Africa/Cairo')::date=gs.day::date),0) AS collected,
   coalesce((SELECT sum(pe.amount) FROM period_expenses pe WHERE pe.expense_date=gs.day::date),0) AS expenses
  FROM generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') AS gs(day)
 ), pipeline AS (
  SELECT count(*) FILTER(WHERE status='received') AS received,
   count(*) FILTER(WHERE status='in_progress') AS in_progress,
   count(*) FILTER(WHERE status='ready') AS ready,
   count(*) FILTER(WHERE status='delivered') AS delivered
  FROM public.invoices WHERE branch_id=v_branch AND status<>'cancelled'
 )
 SELECT jsonb_build_object(
  'invoice_count',(SELECT count(*) FROM period_invoices WHERE status<>'cancelled'),
  'invoice_value',(SELECT coalesce(sum(total_amount),0) FROM period_invoices WHERE status<>'cancelled'),
  'collected',(SELECT coalesce(sum(amount),0) FROM period_payments),
  'payment_count',(SELECT count(*) FROM period_payments),
  'expense_total',(SELECT coalesce(sum(amount),0) FROM period_expenses),
  'expense_count',(SELECT count(*) FROM period_expenses),
  'pipeline',jsonb_build_object('received',pipeline.received,'in_progress',pipeline.in_progress,'ready',pipeline.ready,'delivered',pipeline.delivered),
  'daily',coalesce((SELECT jsonb_agg(jsonb_build_object('date',to_char(day,'DD/MM'),'collected',collected,'expenses',expenses) ORDER BY day) FROM daily),'[]'::jsonb),
  'recent_expenses',coalesce((SELECT jsonb_agg(jsonb_build_object('expense_number',expense_number,'description',description,'amount',amount,'expense_date',expense_date) ORDER BY expense_date DESC,expense_number DESC)
   FROM (SELECT * FROM period_expenses ORDER BY expense_date DESC,expense_number DESC LIMIT 20) e),'[]'::jsonb)
 ) INTO v_result FROM pipeline;
 RETURN v_result;
END; $$;
REVOKE ALL ON FUNCTION public.get_laundry_reports(date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_laundry_reports(date,date) TO authenticated;
