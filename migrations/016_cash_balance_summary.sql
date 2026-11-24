-- Server-side complete balance calculation; does not truncate at the REST row limit.
create or replace function public.get_laundry_cash_balances()
returns jsonb language sql stable security invoker set search_path=public,private,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'cash_account_id',ca.id,
   'balance',ca.opening_balance+coalesce(m.net_amount,0)
 ) order by ca.name),'[]'::jsonb)
 from public.cash_accounts ca
 left join (
   select cash_account_id,sum(case when direction='in' then amount else -amount end) as net_amount
   from public.cash_transactions group by cash_account_id
 ) m on m.cash_account_id=ca.id
 where ca.branch_id in (select private.user_branch_ids())
   and private.user_has_permission('cash.view')
$$;
revoke all on function public.get_laundry_cash_balances() from public, anon;
grant execute on function public.get_laundry_cash_balances() to authenticated;
