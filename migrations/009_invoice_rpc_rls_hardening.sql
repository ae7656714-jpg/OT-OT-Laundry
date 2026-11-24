-- Harden invoice RPC: run as caller and authorize the supporting inserts through RLS.
DROP POLICY IF EXISTS invoice_status_history_insert_invoice_create ON public.invoice_status_history;
CREATE POLICY invoice_status_history_insert_invoice_create
ON public.invoice_status_history FOR INSERT TO authenticated
WITH CHECK (
  branch_id IN (SELECT private.user_branch_ids())
  AND changed_by = auth.uid()
  AND private.user_has_permission('invoices.create')
);

DROP POLICY IF EXISTS audit_logs_insert_invoice_create ON public.audit_logs;
CREATE POLICY audit_logs_insert_invoice_create
ON public.audit_logs FOR INSERT TO authenticated
WITH CHECK (
  branch_id IN (SELECT private.user_branch_ids())
  AND actor_user_id = auth.uid()
  AND private.user_has_permission('invoices.create')
);

DROP POLICY IF EXISTS idempotency_keys_insert_invoice_create ON public.idempotency_keys;
CREATE POLICY idempotency_keys_insert_invoice_create
ON public.idempotency_keys FOR INSERT TO authenticated
WITH CHECK (
  branch_id IN (SELECT private.user_branch_ids())
  AND private.user_has_permission('invoices.create')
);

ALTER FUNCTION public.create_laundry_invoice(text,text,jsonb,text,numeric,text,text) SECURITY INVOKER;
