-- Consolidate compatible insert policies to avoid multiple permissive checks.
drop policy if exists audit_logs_insert_expense_approval on public.audit_logs;
drop policy if exists audit_logs_insert_invoice_create on public.audit_logs;
drop policy if exists audit_logs_insert_payment_policy on public.audit_logs;
create policy audit_logs_insert_authorized_events on public.audit_logs
for insert to authenticated
with check (
 branch_id in (select private.user_branch_ids())
 and actor_user_id=(select auth.uid())
 and (
   private.user_has_permission('invoices.create')
   or (private.user_has_permission('payments.create') and entity_table='payments')
   or (private.user_has_permission('expenses.approve') and entity_table='expenses' and action in ('expense_approved','expense_rejected'))
 )
);

drop policy if exists cash_transactions_insert_payment_policy on public.cash_transactions;
drop policy if exists cash_transactions_insert_policy_v2 on public.cash_transactions;
create policy cash_transactions_insert_authorized_ledger on public.cash_transactions
for insert to authenticated
with check (
 branch_id in (select private.user_branch_ids())
 and created_by=(select auth.uid())
 and (
   private.user_has_permission('cash.manage')
   or (private.user_has_permission('payments.create') and transaction_type='invoice_payment' and direction='in')
 )
);
