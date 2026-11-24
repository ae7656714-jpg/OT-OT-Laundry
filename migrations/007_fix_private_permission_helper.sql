-- Fix helper reference after moving user_branch_ids() to the private schema.
create or replace function private.user_has_permission(permission_code text)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists (
    select 1 from public.user_roles ur
    join public.profiles pr on pr.id = ur.user_id and pr.is_active = true
    join public.roles r on r.id = ur.role_id
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions pm on pm.id = rp.permission_id
    where ur.user_id = (select auth.uid())
      and pm.code = permission_code
      and (ur.branch_id is null or ur.branch_id in (select private.user_branch_ids()))
  )
$function$;
