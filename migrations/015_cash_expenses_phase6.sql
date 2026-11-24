-- OT Laundry Phase 6: transactional expense recording, approval and cash transfers.
create or replace function public.create_laundry_expense(
 p_category_id uuid, p_description text, p_amount numeric, p_cash_account_id uuid,
 p_expense_date date default current_date, p_notes text default null
) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_expense_id uuid; v_no bigint; v_status text;
 v_balance numeric(14,2); v_amount numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('expenses.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active=true;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if p_description is null or length(trim(p_description))=0 then raise exception 'DESCRIPTION_REQUIRED' using errcode='22023'; end if;
 if p_amount is null or p_amount<=0 or p_amount>999999999 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 v_amount:=round(p_amount,2);
 if v_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 if p_category_id is not null and not exists(select 1 from public.expense_categories where id=p_category_id and branch_id=v_branch and is_active) then raise exception 'CATEGORY_INVALID' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':cash-ledger'));
 select id into v_expense_id from public.cash_accounts where id=p_cash_account_id and branch_id=v_branch and is_active for update;
 if v_expense_id is null then raise exception 'CASH_ACCOUNT_INVALID' using errcode='22023'; end if;
 select ca.opening_balance + coalesce(sum(case when ct.direction='in' then ct.amount else -ct.amount end),0)
 into v_balance from public.cash_accounts ca left join public.cash_transactions ct on ct.cash_account_id=ca.id
 where ca.id=p_cash_account_id and ca.branch_id=v_branch group by ca.id,ca.opening_balance;
 if v_amount>coalesce(v_balance,0) then raise exception 'INSUFFICIENT_CASH' using errcode='22023'; end if;
 v_status:=case when private.user_has_permission('expenses.approve') then 'approved' else 'pending' end;
 perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':expense-number'));
 select coalesce(max(expense_number),0)+1 into v_no from public.expenses where branch_id=v_branch;
 insert into public.expenses(branch_id,expense_number,category_id,description,amount,cash_account_id,expense_date,approval_status,paid_by,notes)
 values(v_branch,v_no,p_category_id,trim(p_description),v_amount,p_cash_account_id,coalesce(p_expense_date,current_date),v_status,v_uid,nullif(trim(coalesce(p_notes,'')),''))
 returning id into v_expense_id;
 if v_status='approved' then
  insert into public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,expense_id,reference,description,created_by)
  values(v_branch,p_cash_account_id,'expense','out',v_amount,v_expense_id,'EXP-'||v_no,'مصروف: '||trim(p_description),v_uid);
 end if;
 return jsonb_build_object('expense_id',v_expense_id,'expense_number',v_no,'approval_status',v_status,'amount',v_amount);
end; $$;

create or replace function public.approve_laundry_expense(p_expense_id uuid, p_approve boolean default true, p_reason text default null)
returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_status text; v_account uuid; v_amount numeric(14,2); v_description text; v_balance numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('expenses.approve') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id,approval_status,cash_account_id,amount,description into v_branch,v_status,v_account,v_amount,v_description
 from public.expenses where id=p_expense_id and branch_id in (select private.user_branch_ids()) for update;
 if v_branch is null then raise exception 'EXPENSE_NOT_FOUND' using errcode='P0002'; end if;
 if v_status<>'pending' then raise exception 'EXPENSE_NOT_PENDING' using errcode='22023'; end if;
 if p_approve then
  perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':cash-ledger'));
  select ca.opening_balance + coalesce(sum(case when ct.direction='in' then ct.amount else -ct.amount end),0)
  into v_balance from public.cash_accounts ca left join public.cash_transactions ct on ct.cash_account_id=ca.id
  where ca.id=v_account and ca.branch_id=v_branch and ca.is_active group by ca.id,ca.opening_balance;
  if v_balance is null or v_amount>v_balance then raise exception 'INSUFFICIENT_CASH' using errcode='22023'; end if;
  update public.expenses set approval_status='approved',updated_at=now() where id=p_expense_id;
  insert into public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,expense_id,reference,description,created_by)
  values(v_branch,v_account,'expense','out',v_amount,p_expense_id,'EXP-'||p_expense_id::text,'مصروف: '||v_description,v_uid);
 else
  update public.expenses set approval_status='rejected',updated_at=now() where id=p_expense_id;
 end if;
 insert into public.audit_logs(branch_id,actor_user_id,action,entity_table,entity_id,reason,new_values)
 values(v_branch,v_uid,case when p_approve then 'expense_approved' else 'expense_rejected' end,'expenses',p_expense_id::text,nullif(trim(coalesce(p_reason,'')),''),jsonb_build_object('approval_status',case when p_approve then 'approved' else 'rejected' end));
 return jsonb_build_object('expense_id',p_expense_id,'approval_status',case when p_approve then 'approved' else 'rejected' end);
end; $$;

create or replace function public.transfer_laundry_cash(p_from_account_id uuid,p_to_account_id uuid,p_amount numeric,p_reason text default null)
returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_branch uuid; v_from_balance numeric(14,2); v_transfer_id uuid; v_amount numeric(14,2);
begin
 if v_uid is null or not private.user_has_permission('cash.manage') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 select branch_id into v_branch from public.profiles where id=v_uid and is_active=true;
 if v_branch is null or not (v_branch in (select private.user_branch_ids())) then raise exception 'BRANCH_FORBIDDEN' using errcode='42501'; end if;
 if p_from_account_id is null or p_to_account_id is null or p_from_account_id=p_to_account_id then raise exception 'INVALID_ACCOUNTS' using errcode='22023'; end if;
 if p_amount is null or p_amount<=0 or p_amount>999999999 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 v_amount:=round(p_amount,2);
 if v_amount<=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtext(v_branch::text||':cash-ledger'));
 perform 1 from public.cash_accounts where branch_id=v_branch and id in (p_from_account_id,p_to_account_id) and is_active order by id for update;
 if (select count(*) from public.cash_accounts where branch_id=v_branch and id in (p_from_account_id,p_to_account_id) and is_active)<>2 then raise exception 'CASH_ACCOUNT_INVALID' using errcode='22023'; end if;
 select ca.opening_balance+coalesce(sum(case when ct.direction='in' then ct.amount else -ct.amount end),0)
 into v_from_balance from public.cash_accounts ca left join public.cash_transactions ct on ct.cash_account_id=ca.id
 where ca.id=p_from_account_id and ca.branch_id=v_branch group by ca.id,ca.opening_balance;
 if v_amount>coalesce(v_from_balance,0) then raise exception 'INSUFFICIENT_CASH' using errcode='22023'; end if;
 insert into public.cash_transfers(branch_id,from_account_id,to_account_id,amount,reason,transferred_by)
 values(v_branch,p_from_account_id,p_to_account_id,v_amount,nullif(trim(coalesce(p_reason,'')),''),v_uid) returning id into v_transfer_id;
 insert into public.cash_transactions(branch_id,cash_account_id,transaction_type,direction,amount,reference,description,created_by)
 values
 (v_branch,p_from_account_id,'transfer_out','out',v_amount,'TRF-'||v_transfer_id::text,'تحويل إلى خزينة أخرى',v_uid),
 (v_branch,p_to_account_id,'transfer_in','in',v_amount,'TRF-'||v_transfer_id::text,'تحويل من خزينة أخرى',v_uid);
 return jsonb_build_object('transfer_id',v_transfer_id,'amount',v_amount);
end; $$;

revoke all on function public.create_laundry_expense(uuid,text,numeric,uuid,date,text) from public, anon;
grant execute on function public.create_laundry_expense(uuid,text,numeric,uuid,date,text) to authenticated;
revoke all on function public.approve_laundry_expense(uuid,boolean,text) from public, anon;
grant execute on function public.approve_laundry_expense(uuid,boolean,text) to authenticated;
revoke all on function public.transfer_laundry_cash(uuid,uuid,numeric,text) from public, anon;
grant execute on function public.transfer_laundry_cash(uuid,uuid,numeric,text) to authenticated;
