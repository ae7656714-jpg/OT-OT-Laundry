-- Seed an empty Demo branch after the first administrator is bootstrapped.
-- No prices or operational transactions are invented.
create or replace function private.seed_branch_defaults(p_branch_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.garment_categories(branch_id,name,name_en,sort_order,is_active)
  select p_branch_id,v.name_ar,v.name_en,v.sort_order,true
  from (values ('رجالي','Men',1),('حريمي','Women',2),('أطفالي','Children',3),('أخرى','Other',4)) v(name_ar,name_en,sort_order)
  where not exists(select 1 from public.garment_categories c where c.branch_id=p_branch_id and c.name=v.name_ar);

  insert into public.services(branch_id,name,name_en,description,sort_order,is_active)
  select p_branch_id,v.name_ar,v.name_en,v.description,v.sort_order,true
  from (values
    ('غسيل','Washing','غسيل القطع',1),('كي','Ironing','كي القطع',2),
    ('غسيل + كي','Wash & Iron','غسيل وكي',3),('تنظيف جاف','Dry Cleaning','تنظيف جاف للقطع المناسبة',4),
    ('إزالة بقع','Stain Removal','معالجة البقع',5)
  ) v(name_ar,name_en,description,sort_order)
  where not exists(select 1 from public.services s where s.branch_id=p_branch_id and s.name=v.name_ar);

  insert into public.garment_types(branch_id,category_id,name,name_en,icon_key,sort_order,is_active)
  select p_branch_id,c.id,v.name_ar,v.name_en,v.icon_key,v.sort_order,true
  from (values
    ('رجالي','قميص','Shirt','shirt',1),('رجالي','تيشيرت','T-Shirt','shirt',2),
    ('رجالي','بنطلون','Trousers','pants',3),('رجالي','جاكيت','Jacket','jacket',4),
    ('حريمي','بلوزة','Blouse','shirt',1),('حريمي','فستان','Dress','dress',2),('حريمي','جيبة','Skirt','skirt',3),
    ('أطفالي','تيشيرت أطفال','Kids T-Shirt','shirt',1),('أطفالي','بنطلون أطفال','Kids Trousers','pants',2),
    ('أخرى','ملاية سرير','Bedsheet','linen',1),('أخرى','بطانية','Blanket','linen',2),('أخرى','فوطة','Towel','linen',3)
  ) v(category_name,name_ar,name_en,icon_key,sort_order)
  join public.garment_categories c on c.branch_id=p_branch_id and c.name=v.category_name
  where not exists(select 1 from public.garment_types gt where gt.branch_id=p_branch_id and gt.category_id=c.id and gt.name=v.name_ar);

  insert into public.garment_services(branch_id,garment_type_id,service_id,default_price,is_available)
  select p_branch_id,gt.id,s.id,null,true
  from public.garment_types gt join public.services s on s.branch_id=p_branch_id and s.is_active
  where gt.branch_id=p_branch_id and gt.is_active
    and not exists(select 1 from public.garment_services gs where gs.branch_id=p_branch_id and gs.garment_type_id=gt.id and gs.service_id=s.id);

  insert into public.cash_accounts(branch_id,code,name,account_type,opening_balance,is_active)
  select p_branch_id,'MAIN-CASH','الخزينة الرئيسية','cash',0,true
  where not exists(select 1 from public.cash_accounts ca where ca.branch_id=p_branch_id and ca.code='MAIN-CASH');

  insert into public.expense_categories(branch_id,name,is_active)
  select p_branch_id,v.name,true from (values ('مستلزمات تشغيل'),('مرافق'),('صيانة'),('إيجار'),('أجور'),('أخرى')) v(name)
  where not exists(select 1 from public.expense_categories ec where ec.branch_id=p_branch_id and ec.name=v.name);

  insert into public.payroll_attendance_rules(branch_id,monthly_work_days,daily_work_hours,overtime_multiplier,late_deduction_multiplier,absence_deduction_multiplier)
  select p_branch_id,30,8,1.5,1,1
  where not exists(select 1 from public.payroll_attendance_rules pr where pr.branch_id=p_branch_id);
end;
$$;
revoke all on function private.seed_branch_defaults(uuid) from public,anon,authenticated;
grant execute on function private.seed_branch_defaults(uuid) to service_role;

create or replace function public.bootstrap_first_admin(
  p_user_id uuid,p_username text,p_full_name text,p_branch_code text,p_branch_name text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_branch_id uuid; v_role_id uuid; v_role_claim text;
begin
  v_role_claim:=current_setting('request.jwt.claim.role',true);
  if v_role_claim is distinct from 'service_role' then raise exception 'Not authorized'; end if;
  perform pg_advisory_xact_lock(hashtext('ot_laundry_first_admin_bootstrap'));
  if exists(select 1 from public.profiles) then raise exception 'Initial administrator has already been created'; end if;
  if p_user_id is null or p_username is null or p_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
     or p_username<>lower(p_username) or nullif(trim(p_full_name),'') is null
     or nullif(trim(p_branch_code),'') is null or nullif(trim(p_branch_name),'') is null then
    raise exception 'Invalid initial administrator details';
  end if;
  insert into public.branches(code,name) values(trim(p_branch_code),trim(p_branch_name)) returning id into v_branch_id;
  insert into public.profiles(id,username,full_name,branch_id,is_active)
    values(p_user_id,p_username,trim(p_full_name),v_branch_id,true);
  select id into v_role_id from public.roles where code='system_admin';
  if v_role_id is null then raise exception 'System administrator role is missing'; end if;
  insert into public.user_roles(user_id,role_id,branch_id) values(p_user_id,v_role_id,v_branch_id);
  perform private.seed_branch_defaults(v_branch_id);
  return v_branch_id;
end;
$$;
revoke all on function public.bootstrap_first_admin(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.bootstrap_first_admin(uuid,text,text,text,text) to service_role;
