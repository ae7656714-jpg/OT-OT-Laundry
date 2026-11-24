-- Applied to Supabase project OT-Laundry.
begin;

alter table public.profiles add column if not exists username text;
create unique index if not exists uq_profiles_username_ci
  on public.profiles (lower(username)) where username is not null;

alter table public.profiles drop constraint if exists profiles_username_format_check;
alter table public.profiles add constraint profiles_username_format_check
  check (username is null or (username = lower(username) and username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'));

drop function if exists public.bootstrap_first_admin(text,text,text);
create or replace function public.bootstrap_first_admin(
  p_user_id uuid, p_username text, p_full_name text, p_branch_code text, p_branch_name text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_branch_id uuid; v_role_id uuid; v_role_claim text;
begin
  v_role_claim := current_setting('request.jwt.claim.role', true);
  if v_role_claim is distinct from 'service_role' then raise exception 'Not authorized'; end if;
  perform pg_advisory_xact_lock(hashtext('ot_laundry_first_admin_bootstrap'));
  if exists (select 1 from public.profiles) then raise exception 'Initial administrator has already been created'; end if;
  if p_user_id is null or p_username is null or p_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
     or p_username <> lower(p_username) or nullif(trim(p_full_name), '') is null
     or nullif(trim(p_branch_code), '') is null or nullif(trim(p_branch_name), '') is null then
    raise exception 'Invalid initial administrator details';
  end if;
  insert into public.branches(code,name) values (trim(p_branch_code),trim(p_branch_name)) returning id into v_branch_id;
  insert into public.profiles(id,username,full_name,branch_id,is_active)
    values (p_user_id,p_username,trim(p_full_name),v_branch_id,true);
  select id into v_role_id from public.roles where code='system_admin';
  if v_role_id is null then raise exception 'System administrator role is missing'; end if;
  insert into public.user_roles(user_id,role_id,branch_id) values (p_user_id,v_role_id,v_branch_id);
  return v_branch_id;
end;
$$;
revoke all on function public.bootstrap_first_admin(uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.bootstrap_first_admin(uuid,text,text,text,text) to service_role;
commit;
