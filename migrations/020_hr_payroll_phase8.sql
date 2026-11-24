-- Phase 8: Human resources, attendance, leave, advances and payroll.
-- All RPCs run as SECURITY INVOKER and are protected by branch RLS + permissions.

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='hr' and p.code in ('payroll.view','cash.view')
on conflict do nothing;

alter table public.cash_transactions drop constraint if exists cash_transactions_transaction_type_check;
alter table public.cash_transactions add constraint cash_transactions_transaction_type_check
check (transaction_type = any(array[
 'opening','invoice_payment','expense','payment_reversal','transfer_in','transfer_out','adjustment',
 'salary_payment','employee_advance','advance_repayment'
]));

drop policy if exists cash_transactions_insert_payroll on public.cash_transactions;
drop policy if exists audit_logs_insert_hr on public.audit_logs;
drop policy if exists audit_logs_insert_payroll on public.audit_logs;
drop policy if exists cash_transactions_insert_authorized_ledger on public.cash_transactions;
create policy cash_transactions_insert_authorized_ledger on public.cash_transactions
for insert to authenticated
with check (
 branch_id in (select private.user_branch_ids())
 and created_by=(select auth.uid())
 and (
   private.user_has_permission('cash.manage')
   or (private.user_has_permission('payments.create') and transaction_type='invoice_payment' and direction='in')
   or (private.user_has_permission('payroll.manage') and transaction_type in ('salary_payment','employee_advance','advance_repayment'))
 )
);

drop policy if exists audit_logs_insert_authorized_events on public.audit_logs;
create policy audit_logs_insert_authorized_events on public.audit_logs
for insert to authenticated
with check (
 branch_id in (select private.user_branch_ids())
 and actor_user_id=(select auth.uid())
 and (
   private.user_has_permission('invoices.create')
   or (private.user_has_permission('payments.create') and entity_table='payments')
   or (private.user_has_permission('expenses.approve') and entity_table='expenses' and action in ('expense_approved','expense_rejected'))
   or (private.user_has_permission('hr.manage') and entity_table in ('employees','attendance','leave_requests','departments','shifts'))
   or (private.user_has_permission('payroll.manage') and entity_table in ('employee_advances','advance_repayments','payroll_periods','payroll_items','salary_payments'))
 )
);

create or replace function public.issue_employee_advance(
 p_employee_id uuid,p_cash_account_id uuid,p_amount numeric,p_reason text default null,p_advance_date date default current_date
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_advance uuid; v_balance numeric(14,2); v_amount numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 v_amount:=round(p_amount,2);
 if v_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 if not exists(select 1 from public.employees where id=p_employee_id and branch_id=v_branch and employment_status='active') then raise exception 'EMPLOYEE_INVALID' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':cash-ledger'));
 perform 1 from public.cash_accounts where id=p_cash_account_id and branch_id=v_branch and is_active;
 if not found then raise exception 'CASH_ACCOUNT_INVALID' using errcode='22023'; end if;
 select ca.opening_balance+coalesce(sum(case when ct.direction='in' then ct.amount else -ct.amount end),0)
 into v_balance from public.cash_accounts ca left join public.cash_transactions ct on ct.cash_account_id=ca.id
 where ca.id=p_cash_account_id and ca.branch_id=v_branch group by ca.id,ca.opening_balance;
 if v_amount>coalesce(v_balance,0) then raise exception 'INSUFFICIENT_CASH' using errcode='22023'; end if;
 insert into public.employee_advances(branch_id,employee_id,cash_account_id,amount,advance_date,reason,issued_by)
 values(v_branch,p_employee_id,p_cash_account_id,v_amount,coalesce(p_advance_date,current_date),nullif(trim(coalesce(p_reason,'')),''),v_uid)
 returning id into v_advance;
 insert into public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,reference,description,created_by)
 values(v_branch,p_cash_account_id,'employee_advance','out',v_amount,'ADV-'||v_advance::text,'سلفة موظف',v_uid);
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
 values(v_branch,v_uid,'employee_advance_issued','employee_advances',v_advance::text,jsonb_build_object('employee_id',p_employee_id,'amount',v_amount));
 return jsonb_build_object('advance_id',v_advance,'amount',v_amount);
end; $$;

create or replace function public.repay_employee_advance(
 p_advance_id uuid,p_cash_account_id uuid,p_amount numeric,p_repayment_date date default current_date,p_notes text default null
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_advance_branch uuid; v_remaining numeric(14,2); v_advance_amount numeric(14,2); v_repayment uuid; v_amount numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 v_amount:=round(p_amount,2); if v_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':cash-ledger'));
 select branch_id,amount into v_advance_branch,v_advance_amount from public.employee_advances
 where id=p_advance_id and branch_id in (select private.user_branch_ids()) and status in ('open','partially_repaid') for update;
 if v_advance_branch is null then raise exception 'ADVANCE_NOT_OPEN' using errcode='P0002'; end if;
 select v_advance_amount-coalesce(sum(amount),0) into v_remaining from public.advance_repayments where advance_id=p_advance_id;
 if v_amount>v_remaining then raise exception 'REPAYMENT_EXCEEDS_BALANCE' using errcode='22023'; end if;
 perform 1 from public.cash_accounts where id=p_cash_account_id and branch_id=v_branch and is_active;
 if not found then raise exception 'CASH_ACCOUNT_INVALID' using errcode='22023'; end if;
 insert into public.advance_repayments(branch_id,advance_id,amount,repayment_date,cash_account_id,received_by,notes)
 values(v_branch,p_advance_id,v_amount,coalesce(p_repayment_date,current_date),p_cash_account_id,v_uid,nullif(trim(coalesce(p_notes,'')),'')) returning id into v_repayment;
 insert into public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,reference,description,created_by)
 values(v_branch,p_cash_account_id,'advance_repayment','in',v_amount,'ADVR-'||v_repayment::text,'تحصيل سداد سلفة',v_uid);
 update public.employee_advances set status=case when v_amount=v_remaining then 'repaid' else 'partially_repaid' end where id=p_advance_id;
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
 values(v_branch,v_uid,'employee_advance_repaid','advance_repayments',v_repayment::text,jsonb_build_object('advance_id',p_advance_id,'amount',v_amount));
 return jsonb_build_object('repayment_id',v_repayment,'remaining_balance',v_remaining-v_amount);
end; $$;

create or replace function public.create_payroll_period(
 p_period_name text,p_start_date date,p_end_date date,p_adjustments jsonb default '[]'::jsonb
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_period uuid; v_adj jsonb; v_emp uuid; v_basic numeric(14,2); v_add numeric(14,2); v_ded numeric(14,2); v_adv_ded numeric(14,2); v_net numeric(14,2); v_item uuid; v_left numeric(14,2); v_due numeric(14,2); v_adv record; v_count int:=0;
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if nullif(trim(coalesce(p_period_name,'')),'') is null or p_start_date is null or p_end_date is null or p_end_date<p_start_date then raise exception 'INVALID_PERIOD' using errcode='22023'; end if;
 if jsonb_typeof(coalesce(p_adjustments,'[]'::jsonb))<>'array' then raise exception 'INVALID_ADJUSTMENTS' using errcode='22023'; end if;
 if exists(select 1 from public.payroll_periods where branch_id=v_branch and period_name=trim(p_period_name)) then raise exception 'PERIOD_EXISTS' using errcode='23505'; end if;
 insert into public.payroll_periods(branch_id,period_name,start_date,end_date,status)
 values(v_branch,trim(p_period_name),p_start_date,p_end_date,'draft') returning id into v_period;
 for v_adj in select value from jsonb_array_elements(coalesce(p_adjustments,'[]'::jsonb)) loop
  v_emp:=(v_adj->>'employee_id')::uuid;
  select base_salary into v_basic from public.employees where id=v_emp and branch_id=v_branch and employment_status='active';
  if not found then raise exception 'EMPLOYEE_INVALID' using errcode='22023'; end if;
  v_add:=round(coalesce((v_adj->>'additions')::numeric,0),2);
  v_ded:=round(coalesce((v_adj->>'deductions')::numeric,0),2);
  v_adv_ded:=round(coalesce((v_adj->>'advances_deduction')::numeric,0),2);
  if least(v_add,v_ded,v_adv_ded)<0 then raise exception 'INVALID_ADJUSTMENT' using errcode='22023'; end if;
  v_net:=v_basic+v_add-v_ded-v_adv_ded;
  if v_net<0 then raise exception 'NEGATIVE_NET_SALARY' using errcode='22023'; end if;
  insert into public.payroll_items(branch_id,payroll_period_id,employee_id,basic_salary,additions,deductions,advances_deduction,net_salary,notes)
  values(v_branch,v_period,v_emp,v_basic,v_add,v_ded,v_adv_ded,v_net,nullif(trim(coalesce(v_adj->>'notes','')),'')) returning id into v_item;
  v_left:=v_adv_ded;
  if v_left>0 then
   for v_adv in
    select ea.id,ea.amount-coalesce((select sum(ar.amount) from public.advance_repayments ar where ar.advance_id=ea.id),0) as remaining
    from public.employee_advances ea where ea.branch_id=v_branch and ea.employee_id=v_emp and ea.status in ('open','partially_repaid')
    order by ea.advance_date,ea.created_at for update
   loop
    exit when v_left<=0;
    v_due:=least(v_left,v_adv.remaining);
    if v_due>0 then
     insert into public.advance_repayments(branch_id,advance_id,amount,repayment_date,payroll_item_id,received_by,notes)
     values(v_branch,v_adv.id,v_due,p_end_date,v_item,v_uid,'خصم سلفة من مسير الرواتب');
     update public.employee_advances set status=case when v_due=v_adv.remaining then 'repaid' else 'partially_repaid' end where id=v_adv.id;
     v_left:=v_left-v_due;
    end if;
   end loop;
   if v_left>0 then raise exception 'ADVANCE_DEDUCTION_EXCEEDS_BALANCE' using errcode='22023'; end if;
  end if;
  v_count:=v_count+1;
 end loop;
 if v_count=0 then raise exception 'NO_PAYROLL_EMPLOYEES' using errcode='22023'; end if;
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
 values(v_branch,v_uid,'payroll_period_created','payroll_periods',v_period::text,jsonb_build_object('period_name',p_period_name,'items',v_count));
 return jsonb_build_object('payroll_period_id',v_period,'items_count',v_count);
end; $$;

create or replace function public.approve_payroll_period(p_period_id uuid)
returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_status text; v_count int;
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id,status into v_branch,v_status from public.payroll_periods where id=p_period_id and branch_id in (select private.user_branch_ids()) for update;
 if v_branch is null then raise exception 'PERIOD_NOT_FOUND' using errcode='P0002'; end if;
 if v_status<>'draft' then raise exception 'PERIOD_NOT_DRAFT' using errcode='22023'; end if;
 select count(*) into v_count from public.payroll_items where payroll_period_id=p_period_id and branch_id=v_branch;
 if v_count=0 then raise exception 'EMPTY_PAYROLL' using errcode='22023'; end if;
 update public.payroll_periods set status='approved',approved_by=v_uid,approved_at=now() where id=p_period_id;
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
 values(v_branch,v_uid,'payroll_period_approved','payroll_periods',p_period_id::text,jsonb_build_object('items_count',v_count));
 return jsonb_build_object('payroll_period_id',p_period_id,'status','approved');
end; $$;

create or replace function public.pay_payroll_item(
 p_payroll_item_id uuid,p_cash_account_id uuid,p_amount numeric,p_reference text default null
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_period_id uuid; v_period_status text; v_net numeric(14,2); v_paid numeric(14,2); v_balance numeric(14,2); v_opening numeric(14,2); v_cash_balance numeric(14,2); v_payment uuid; v_amount numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 v_amount:=round(p_amount,2); if v_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 select pi.branch_id,pi.payroll_period_id,pi.net_salary,pp.status into v_branch,v_period_id,v_net,v_period_status
 from public.payroll_items pi join public.payroll_periods pp on pp.id=pi.payroll_period_id
 where pi.id=p_payroll_item_id and pi.branch_id in (select private.user_branch_ids()) for update of pi,pp;
 if v_branch is null then raise exception 'PAYROLL_ITEM_NOT_FOUND' using errcode='P0002'; end if;
 if v_period_status not in ('approved','paid') then raise exception 'PAYROLL_NOT_APPROVED' using errcode='22023'; end if;
 select coalesce(sum(amount),0) into v_paid from public.salary_payments where payroll_item_id=p_payroll_item_id;
 v_balance:=v_net-v_paid;
 if v_amount>v_balance then raise exception 'PAYMENT_EXCEEDS_SALARY_BALANCE' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':cash-ledger'));
 select opening_balance into v_opening from public.cash_accounts where id=p_cash_account_id and branch_id=v_branch and is_active;
 if v_opening is null then raise exception 'CASH_ACCOUNT_INVALID' using errcode='22023'; end if;
 select v_opening+coalesce(sum(case when direction='in' then amount else -amount end),0) into v_cash_balance
 from public.cash_transactions where cash_account_id=p_cash_account_id;
 if v_amount>coalesce(v_cash_balance,0) then raise exception 'INSUFFICIENT_CASH' using errcode='22023'; end if;
 insert into public.salary_payments(branch_id,payroll_item_id,cash_account_id,amount,paid_by,reference)
 values(v_branch,p_payroll_item_id,p_cash_account_id,v_amount,v_uid,nullif(trim(coalesce(p_reference,'')),'')) returning id into v_payment;
 insert into public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,reference,description,created_by)
 values(v_branch,p_cash_account_id,'salary_payment','out',v_amount,'SAL-'||v_payment::text,'صرف راتب موظف',v_uid);
 if not exists(select 1 from public.payroll_items pi where pi.payroll_period_id=v_period_id
  and pi.net_salary>coalesce((select sum(sp.amount) from public.salary_payments sp where sp.payroll_item_id=pi.id),0)) then
  update public.payroll_periods set status='paid' where id=v_period_id;
 end if;
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,new_values)
 values(v_branch,v_uid,'salary_payment_recorded','salary_payments',v_payment::text,jsonb_build_object('payroll_item_id',p_payroll_item_id,'amount',v_amount));
 return jsonb_build_object('salary_payment_id',v_payment,'remaining_salary',v_balance-v_amount);
end; $$;

revoke all on function public.issue_employee_advance(uuid,uuid,numeric,text,date) from public,anon;
grant execute on function public.issue_employee_advance(uuid,uuid,numeric,text,date) to authenticated;
revoke all on function public.repay_employee_advance(uuid,uuid,numeric,date,text) from public,anon;
grant execute on function public.repay_employee_advance(uuid,uuid,numeric,date,text) to authenticated;
revoke all on function public.create_payroll_period(text,date,date,jsonb) from public,anon;
grant execute on function public.create_payroll_period(text,date,date,jsonb) to authenticated;
revoke all on function public.approve_payroll_period(uuid) from public,anon;
grant execute on function public.approve_payroll_period(uuid) to authenticated;
revoke all on function public.pay_payroll_item(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.pay_payroll_item(uuid,uuid,numeric,text) to authenticated;
