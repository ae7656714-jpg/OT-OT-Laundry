-- OT Laundry Phase 9: configurable attendance-to-payroll calculations
create table if not exists public.payroll_attendance_rules (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null unique references public.branches(id) on delete cascade,
  monthly_work_days numeric(5,2) not null default 30 check (monthly_work_days between 1 and 31),
  daily_work_hours numeric(5,2) not null default 8 check (daily_work_hours between 1 and 24),
  overtime_multiplier numeric(5,2) not null default 1.50 check (overtime_multiplier between 0 and 5),
  late_deduction_multiplier numeric(5,2) not null default 1.00 check (late_deduction_multiplier between 0 and 5),
  absence_deduction_multiplier numeric(5,2) not null default 1.00 check (absence_deduction_multiplier between 0 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.payroll_attendance_rules enable row level security;
grant select, insert, update on public.payroll_attendance_rules to authenticated;
drop policy if exists payroll_attendance_rules_select on public.payroll_attendance_rules;
create policy payroll_attendance_rules_select on public.payroll_attendance_rules for select to authenticated
using (branch_id in (select private.user_branch_ids()) and private.user_has_permission('payroll.manage'));
drop policy if exists payroll_attendance_rules_insert on public.payroll_attendance_rules;
create policy payroll_attendance_rules_insert on public.payroll_attendance_rules for insert to authenticated
with check (branch_id in (select private.user_branch_ids()) and private.user_has_permission('payroll.manage'));
drop policy if exists payroll_attendance_rules_update on public.payroll_attendance_rules;
create policy payroll_attendance_rules_update on public.payroll_attendance_rules for update to authenticated
using (branch_id in (select private.user_branch_ids()) and private.user_has_permission('payroll.manage'))
with check (branch_id in (select private.user_branch_ids()) and private.user_has_permission('payroll.manage'));

-- Allow auditing of payroll calculation rule changes.
drop policy if exists audit_logs_insert_authorized_events on public.audit_logs;
create policy audit_logs_insert_authorized_events on public.audit_logs for insert to authenticated
with check (branch_id in (select private.user_branch_ids()) and actor_user_id=(select auth.uid()) and (
 private.user_has_permission('invoices.create')
 or (private.user_has_permission('payments.create') and entity_table='payments')
 or (private.user_has_permission('expenses.approve') and entity_table='expenses' and action in ('expense_approved','expense_rejected'))
 or (private.user_has_permission('hr.manage') and entity_table in ('employees','attendance','leave_requests','departments','shifts'))
 or (private.user_has_permission('payroll.manage') and entity_table in ('employee_advances','advance_repayments','payroll_periods','payroll_items','salary_payments','payroll_attendance_rules'))
));

alter table public.payroll_items
  add column if not exists attendance_present_days integer not null default 0,
  add column if not exists attendance_absent_days integer not null default 0,
  add column if not exists attendance_late_minutes integer not null default 0,
  add column if not exists attendance_overtime_minutes integer not null default 0,
  add column if not exists attendance_absence_deduction numeric(14,2) not null default 0,
  add column if not exists attendance_late_deduction numeric(14,2) not null default 0,
  add column if not exists attendance_overtime_addition numeric(14,2) not null default 0;

create or replace function public.get_payroll_attendance_rules()
returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_rules public.payroll_attendance_rules%rowtype;
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 select * into v_rules from public.payroll_attendance_rules where branch_id=v_branch;
 if not found then
   return jsonb_build_object('monthly_work_days',30,'daily_work_hours',8,'overtime_multiplier',1.5,'late_deduction_multiplier',1,'absence_deduction_multiplier',1);
 end if;
 return jsonb_build_object('monthly_work_days',v_rules.monthly_work_days,'daily_work_hours',v_rules.daily_work_hours,
   'overtime_multiplier',v_rules.overtime_multiplier,'late_deduction_multiplier',v_rules.late_deduction_multiplier,
   'absence_deduction_multiplier',v_rules.absence_deduction_multiplier);
end; $$;

create or replace function public.set_payroll_attendance_rules(
 p_monthly_work_days numeric,p_daily_work_hours numeric,p_overtime_multiplier numeric,
 p_late_deduction_multiplier numeric,p_absence_deduction_multiplier numeric
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid;
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if p_monthly_work_days not between 1 and 31 or p_daily_work_hours not between 1 and 24 or
    p_overtime_multiplier not between 0 and 5 or p_late_deduction_multiplier not between 0 and 5 or
    p_absence_deduction_multiplier not between 0 and 5 then raise exception 'INVALID_RULES' using errcode='22023'; end if;
 insert into public.payroll_attendance_rules(branch_id,monthly_work_days,daily_work_hours,overtime_multiplier,late_deduction_multiplier,absence_deduction_multiplier)
 values(v_branch,p_monthly_work_days,p_daily_work_hours,p_overtime_multiplier,p_late_deduction_multiplier,p_absence_deduction_multiplier)
 on conflict(branch_id) do update set monthly_work_days=excluded.monthly_work_days,daily_work_hours=excluded.daily_work_hours,
 overtime_multiplier=excluded.overtime_multiplier,late_deduction_multiplier=excluded.late_deduction_multiplier,
 absence_deduction_multiplier=excluded.absence_deduction_multiplier,updated_at=now();
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,new_values)
 values(v_branch,v_uid,'payroll_attendance_rules_updated','payroll_attendance_rules',jsonb_build_object(
 'monthly_work_days',p_monthly_work_days,'daily_work_hours',p_daily_work_hours,'overtime_multiplier',p_overtime_multiplier,
 'late_deduction_multiplier',p_late_deduction_multiplier,'absence_deduction_multiplier',p_absence_deduction_multiplier));
 return public.get_payroll_attendance_rules();
end; $$;

create or replace function public.get_attendance_payroll_summary(p_start_date date,p_end_date date)
returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_rules jsonb; v_result jsonb;
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if p_start_date is null or p_end_date is null or p_end_date<p_start_date or p_end_date-p_start_date>366 then raise exception 'INVALID_PERIOD' using errcode='22023'; end if;
 v_rules:=public.get_payroll_attendance_rules();
 with employee_totals as (
  select e.id employee_id,e.employee_code,e.full_name,e.base_salary,
   count(a.id) filter(where a.attendance_status in ('present','late'))::int present_days,
   count(a.id) filter(where a.attendance_status='absent' and not exists(
     select 1 from public.leave_requests lr where lr.employee_id=e.id and lr.branch_id=v_branch and lr.status='approved'
       and a.work_date between lr.start_date and lr.end_date))::int absent_days,
   coalesce(sum(case when a.attendance_status in('late','present') and a.shift_id is not null and a.check_in is not null then
    greatest(0,floor(extract(epoch from ((a.check_in at time zone 'Africa/Cairo')::time - s.start_time - make_interval(mins=>s.grace_minutes)))/60))::int else 0 end),0)::int late_minutes,
   coalesce(sum(case when a.shift_id is not null and a.check_out is not null then
    greatest(0,floor(extract(epoch from ((a.check_out at time zone 'Africa/Cairo') - (a.work_date + s.end_time + case when s.end_time<=s.start_time then interval '1 day' else interval '0 day' end)))/60))::int else 0 end),0)::int overtime_minutes
  from public.employees e
  left join public.attendance a on a.employee_id=e.id and a.branch_id=v_branch and a.work_date between p_start_date and p_end_date
  left join public.shifts s on s.id=a.shift_id and s.branch_id=v_branch
  where e.branch_id=v_branch and e.employment_status='active'
  group by e.id,e.employee_code,e.full_name,e.base_salary
 ), calculated as (
  select *,round((base_salary/nullif((v_rules->>'monthly_work_days')::numeric,0))*absent_days*(v_rules->>'absence_deduction_multiplier')::numeric,2) absence_deduction,
   round((base_salary/nullif((v_rules->>'monthly_work_days')::numeric,0)/nullif((v_rules->>'daily_work_hours')::numeric,0)/60)*late_minutes*(v_rules->>'late_deduction_multiplier')::numeric,2) late_deduction,
   round((base_salary/nullif((v_rules->>'monthly_work_days')::numeric,0)/nullif((v_rules->>'daily_work_hours')::numeric,0)/60)*overtime_minutes*(v_rules->>'overtime_multiplier')::numeric,2) overtime_addition
  from employee_totals
 )
 select coalesce(jsonb_agg(jsonb_build_object('employee_id',employee_id,'employee_code',employee_code,'full_name',full_name,
  'base_salary',base_salary,'present_days',present_days,'absent_days',absent_days,'late_minutes',late_minutes,'overtime_minutes',overtime_minutes,
  'absence_deduction',absence_deduction,'late_deduction',late_deduction,'overtime_addition',overtime_addition) order by full_name),'[]'::jsonb)
 into v_result from calculated;
 return jsonb_build_object('rules',v_rules,'employees',v_result,'from',p_start_date,'to',p_end_date);
end; $$;

-- Replace payroll creation so attendance components are stored separately and added to the final salary.
create or replace function public.create_payroll_period(
 p_period_name text,p_start_date date,p_end_date date,p_adjustments jsonb default '[]'::jsonb
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_period uuid; v_adj jsonb; v_emp uuid; v_basic numeric(14,2);
 v_add numeric(14,2); v_ded numeric(14,2); v_adv_ded numeric(14,2); v_net numeric(14,2); v_item uuid;
 v_left numeric(14,2); v_due numeric(14,2); v_adv record; v_count int:=0;
 v_present int; v_absent int; v_late int; v_overtime int; v_abs_ded numeric(14,2); v_late_ded numeric(14,2); v_ot_add numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('payroll.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if nullif(trim(coalesce(p_period_name,'')),'') is null or p_start_date is null or p_end_date is null or p_end_date<p_start_date then raise exception 'INVALID_PERIOD' using errcode='22023'; end if;
 if jsonb_typeof(coalesce(p_adjustments,'[]'::jsonb))<>'array' then raise exception 'INVALID_ADJUSTMENTS' using errcode='22023'; end if;
 if exists(select 1 from public.payroll_periods where branch_id=v_branch and period_name=trim(p_period_name)) then raise exception 'PERIOD_EXISTS' using errcode='23505'; end if;
 insert into public.payroll_periods(branch_id,period_name,start_date,end_date,status) values(v_branch,trim(p_period_name),p_start_date,p_end_date,'draft') returning id into v_period;
 for v_adj in select value from jsonb_array_elements(coalesce(p_adjustments,'[]'::jsonb)) loop
  v_emp:=(v_adj->>'employee_id')::uuid;
  select base_salary into v_basic from public.employees where id=v_emp and branch_id=v_branch and employment_status='active';
  if not found then raise exception 'EMPLOYEE_INVALID' using errcode='22023'; end if;
  v_add:=round(coalesce((v_adj->>'additions')::numeric,0),2); v_ded:=round(coalesce((v_adj->>'deductions')::numeric,0),2);
  v_adv_ded:=round(coalesce((v_adj->>'advances_deduction')::numeric,0),2);
  v_present:=greatest(0,coalesce((v_adj->>'attendance_present_days')::int,0));
  v_absent:=greatest(0,coalesce((v_adj->>'attendance_absent_days')::int,0));
  v_late:=greatest(0,coalesce((v_adj->>'attendance_late_minutes')::int,0));
  v_overtime:=greatest(0,coalesce((v_adj->>'attendance_overtime_minutes')::int,0));
  v_abs_ded:=round(coalesce((v_adj->>'attendance_absence_deduction')::numeric,0),2);
  v_late_ded:=round(coalesce((v_adj->>'attendance_late_deduction')::numeric,0),2);
  v_ot_add:=round(coalesce((v_adj->>'attendance_overtime_addition')::numeric,0),2);
  if least(v_add,v_ded,v_adv_ded,v_abs_ded,v_late_ded,v_ot_add)<0 then raise exception 'INVALID_ADJUSTMENT' using errcode='22023'; end if;
  v_net:=v_basic+v_add+v_ot_add-v_ded-v_abs_ded-v_late_ded-v_adv_ded;
  if v_net<0 then raise exception 'NEGATIVE_NET_SALARY' using errcode='22023'; end if;
  insert into public.payroll_items(branch_id,payroll_period_id,employee_id,basic_salary,additions,deductions,advances_deduction,net_salary,notes,
   attendance_present_days,attendance_absent_days,attendance_late_minutes,attendance_overtime_minutes,attendance_absence_deduction,attendance_late_deduction,attendance_overtime_addition)
  values(v_branch,v_period,v_emp,v_basic,v_add+v_ot_add,v_ded+v_abs_ded+v_late_ded,v_adv_ded,v_net,nullif(trim(coalesce(v_adj->>'notes','')),''),
   v_present,v_absent,v_late,v_overtime,v_abs_ded,v_late_ded,v_ot_add) returning id into v_item;
  v_left:=v_adv_ded;
  if v_left>0 then
   for v_adv in select ea.id,ea.amount-coalesce((select sum(ar.amount) from public.advance_repayments ar where ar.advance_id=ea.id),0) remaining
    from public.employee_advances ea where ea.branch_id=v_branch and ea.employee_id=v_emp and ea.status in ('open','partially_repaid') order by ea.advance_date,ea.created_at for update
   loop
    exit when v_left<=0; v_due:=least(v_left,v_adv.remaining);
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
 values(v_branch,v_uid,'payroll_period_created','payroll_periods',v_period::text,jsonb_build_object('period_name',p_period_name,'items',v_count,'attendance_auto_calculated',true));
 return jsonb_build_object('payroll_period_id',v_period,'items_count',v_count);
end; $$;

revoke all on function public.get_payroll_attendance_rules() from public,anon;
grant execute on function public.get_payroll_attendance_rules() to authenticated;
revoke all on function public.set_payroll_attendance_rules(numeric,numeric,numeric,numeric,numeric) from public,anon;
grant execute on function public.set_payroll_attendance_rules(numeric,numeric,numeric,numeric,numeric) to authenticated;
revoke all on function public.get_attendance_payroll_summary(date,date) from public,anon;
grant execute on function public.get_attendance_payroll_summary(date,date) to authenticated;
revoke all on function public.create_payroll_period(text,date,date,jsonb) from public,anon;
grant execute on function public.create_payroll_period(text,date,date,jsonb) to authenticated;
