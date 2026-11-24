-- OT Laundry invoice workflow RPCs and RLS policies.
-- SECURITY INVOKER: branch isolation and permissions are enforced by private helpers + RLS.

-- Invoice creation must be permitted to users with invoices.create.
drop policy if exists invoices_insert_policy on public.invoices;
create policy invoices_insert_policy on public.invoices for insert to authenticated
with check (branch_id in (select private.user_branch_ids()) and private.user_has_permission('invoices.create'));

drop policy if exists invoices_update_policy on public.invoices;
create policy invoices_update_policy on public.invoices for update to authenticated
using (branch_id in (select private.user_branch_ids()) and
       (private.user_has_permission('invoices.edit') or private.user_has_permission('invoices.status')))
with check (branch_id in (select private.user_branch_ids()) and
            (private.user_has_permission('invoices.edit') or private.user_has_permission('invoices.status')));

drop policy if exists invoices_delete_policy on public.invoices;
create policy invoices_delete_policy on public.invoices for delete to authenticated
using (branch_id in (select private.user_branch_ids()) and private.user_has_permission('invoices.cancel'));

drop policy if exists invoice_items_insert_policy on public.invoice_items;
create policy invoice_items_insert_policy on public.invoice_items for insert to authenticated
with check (branch_id in (select private.user_branch_ids()) and private.user_has_permission('invoices.create'));

drop policy if exists invoice_items_update_policy on public.invoice_items;
create policy invoice_items_update_policy on public.invoice_items for update to authenticated
using (branch_id in (select private.user_branch_ids()) and
       (private.user_has_permission('invoices.edit') or private.user_has_permission('invoices.status')))
with check (branch_id in (select private.user_branch_ids()) and
            (private.user_has_permission('invoices.edit') or private.user_has_permission('invoices.status')));

drop policy if exists invoice_items_delete_policy on public.invoice_items;
create policy invoice_items_delete_policy on public.invoice_items for delete to authenticated
using (branch_id in (select private.user_branch_ids()) and private.user_has_permission('invoices.edit'));

-- Status and work logs are append-only audit records.
drop policy if exists invoice_status_history_insert_invoice_create on public.invoice_status_history;
drop policy if exists invoice_status_history_insert_policy on public.invoice_status_history;
create policy invoice_status_history_insert_authorized on public.invoice_status_history for insert to authenticated
with check (branch_id in (select private.user_branch_ids())
  and changed_by=(select auth.uid())
  and (private.user_has_permission('invoices.create') or private.user_has_permission('invoices.status')));
drop policy if exists invoice_status_history_update_policy on public.invoice_status_history;
drop policy if exists invoice_status_history_delete_policy on public.invoice_status_history;

drop policy if exists invoice_item_work_logs_insert_policy on public.invoice_item_work_logs;
create policy invoice_item_work_logs_insert_policy on public.invoice_item_work_logs for insert to authenticated
with check (branch_id in (select private.user_branch_ids())
  and changed_by=(select auth.uid())
  and private.user_has_permission('invoices.status'));
drop policy if exists invoice_item_work_logs_update_policy on public.invoice_item_work_logs;
drop policy if exists invoice_item_work_logs_delete_policy on public.invoice_item_work_logs;

create or replace function public.update_invoice_item_work_status(
  p_item_id uuid, p_work_status text, p_reason text default null
) returns jsonb
language plpgsql security invoker
set search_path=public,private,pg_temp
as $$
declare
  v_uid uuid:=auth.uid();
  v_branch uuid;
  v_invoice_id uuid;
  v_old_item_status text;
  v_invoice_status text;
  v_new_invoice_status text;
  v_all_completed boolean;
  v_any_started boolean;
begin
  if v_uid is null or not private.user_has_permission('invoices.status') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;
  if p_work_status not in ('pending','in_progress','completed') then
    raise exception 'INVALID_WORK_STATUS' using errcode='22023';
  end if;

  select ii.branch_id,ii.invoice_id,ii.work_status,i.status
    into v_branch,v_invoice_id,v_old_item_status,v_invoice_status
  from public.invoice_items ii
  join public.invoices i on i.id=ii.invoice_id and i.branch_id=ii.branch_id
  where ii.id=p_item_id and ii.branch_id in (select private.user_branch_ids())
  for update of ii,i;

  if v_branch is null then raise exception 'INVOICE_ITEM_NOT_FOUND' using errcode='P0002'; end if;
  if v_invoice_status in ('delivered','cancelled') then
    raise exception 'INVOICE_LOCKED' using errcode='22023';
  end if;

  update public.invoice_items
  set work_status=p_work_status,updated_at=now()
  where id=p_item_id and branch_id=v_branch;

  if v_old_item_status is distinct from p_work_status then
    insert into public.invoice_item_work_logs(branch_id,invoice_item_id,old_status,new_status,notes,changed_by)
    values(v_branch,p_item_id,v_old_item_status,p_work_status,nullif(trim(coalesce(p_reason,'')),''),v_uid);
  end if;

  select bool_and(work_status='completed'),
         bool_or(work_status in ('in_progress','completed'))
    into v_all_completed,v_any_started
  from public.invoice_items
  where invoice_id=v_invoice_id and branch_id=v_branch;

  v_new_invoice_status:=case
    when coalesce(v_all_completed,false) then 'ready'
    when coalesce(v_any_started,false) then 'in_progress'
    else 'received'
  end;

  if v_new_invoice_status is distinct from v_invoice_status then
    update public.invoices
    set status=v_new_invoice_status,
        ready_at=case when v_new_invoice_status='ready' then coalesce(ready_at,now()) else null end,
        updated_by=v_uid,updated_at=now()
    where id=v_invoice_id and branch_id=v_branch;

    insert into public.invoice_status_history(branch_id,invoice_id,old_status,new_status,reason,changed_by)
    values(v_branch,v_invoice_id,v_invoice_status,v_new_invoice_status,
      coalesce(nullif(trim(coalesce(p_reason,'')),''),'تحديث حالة التشغيل'),v_uid);
  end if;

  return jsonb_build_object('invoice_id',v_invoice_id,'item_id',p_item_id,
    'item_status',p_work_status,'invoice_status',v_new_invoice_status);
end;
$$;

create or replace function public.deliver_laundry_invoice(
  p_invoice_id uuid,p_reason text default null
) returns jsonb
language plpgsql security invoker
set search_path=public,private,pg_temp
as $$
declare
  v_uid uuid:=auth.uid();
  v_branch uuid;
  v_old_status text;
  v_all_completed boolean;
begin
  if v_uid is null or not private.user_has_permission('invoices.status') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;

  select branch_id,status into v_branch,v_old_status
  from public.invoices
  where id=p_invoice_id and branch_id in (select private.user_branch_ids())
  for update;

  if v_branch is null then raise exception 'INVOICE_NOT_FOUND' using errcode='P0002'; end if;
  if v_old_status='cancelled' then raise exception 'INVOICE_LOCKED' using errcode='22023'; end if;
  if v_old_status='delivered' then
    return jsonb_build_object('invoice_id',p_invoice_id,'status','delivered','already_delivered',true);
  end if;

  select bool_and(work_status='completed') into v_all_completed
  from public.invoice_items where invoice_id=p_invoice_id and branch_id=v_branch;

  if not coalesce(v_all_completed,false) then
    raise exception 'ITEMS_NOT_COMPLETED' using errcode='22023';
  end if;

  update public.invoices
  set status='delivered',ready_at=coalesce(ready_at,now()),delivered_at=now(),
      updated_by=v_uid,updated_at=now()
  where id=p_invoice_id and branch_id=v_branch;

  insert into public.invoice_status_history(branch_id,invoice_id,old_status,new_status,reason,changed_by)
  values(v_branch,p_invoice_id,v_old_status,'delivered',
    coalesce(nullif(trim(coalesce(p_reason,'')),''),'تسليم الفاتورة'),v_uid);

  return jsonb_build_object('invoice_id',p_invoice_id,'status','delivered','already_delivered',false);
end;
$$;

revoke all on function public.update_invoice_item_work_status(uuid,text,text) from public,anon;
grant execute on function public.update_invoice_item_work_status(uuid,text,text) to authenticated;
revoke all on function public.deliver_laundry_invoice(uuid,text) from public,anon;
grant execute on function public.deliver_laundry_invoice(uuid,text) to authenticated;
