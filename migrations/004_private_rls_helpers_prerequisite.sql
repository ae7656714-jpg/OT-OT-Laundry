-- Private, non-exposed RLS helpers used by later RPCs and policies.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create or replace function private.user_branch_ids()
returns setof uuid
language sql stable security definer
set search_path = ''
as $function$
  select p.branch_id
  from public.profiles p
  where p.id = (select auth.uid()) and p.is_active = true and p.branch_id is not null
  union
  select ur.branch_id
  from public.user_roles ur
  join public.profiles p on p.id = ur.user_id and p.is_active = true
  where ur.user_id = (select auth.uid()) and ur.branch_id is not null
$function$;

revoke all on function private.user_branch_ids() from public, anon;
grant execute on function private.user_branch_ids() to authenticated, service_role;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
