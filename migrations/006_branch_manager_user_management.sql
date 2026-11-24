-- Allows branch managers to manage accounts within their own branch.
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id
from public.roles r join public.permissions p on p.code='users.manage'
where r.code='branch_manager'
on conflict do nothing;
