-- Permit authorized expense approvers to write the corresponding audit event only.
drop policy if exists audit_logs_insert_expense_approval on public.audit_logs;
create policy audit_logs_insert_expense_approval on public.audit_logs
for insert to authenticated
with check (
 branch_id in (select private.user_branch_ids())
 and actor_user_id=auth.uid()
 and private.user_has_permission('expenses.approve')
 and entity_table='expenses'
 and action in ('expense_approved','expense_rejected')
);
