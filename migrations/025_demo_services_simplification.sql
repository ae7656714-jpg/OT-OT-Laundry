-- Demo branch catalog simplification. Preserve old rows and snapshots; only hide unused demo catalog rows.
DO $$
DECLARE
  v_branch uuid;
  v_clothes uuid;
  v_wash_iron uuid;
BEGIN
  SELECT id INTO v_branch FROM public.branches WHERE code='MAIN' ORDER BY created_at LIMIT 1;
  IF v_branch IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM public.invoices WHERE branch_id=v_branch) THEN
    RAISE NOTICE 'Catalog seed skipped because this branch already has invoices.';
    RETURN;
  END IF;

  INSERT INTO public.garment_categories(branch_id,name,name_en,sort_order,is_active)
  VALUES(v_branch,'Clothes','Clothes',1,true)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_clothes FROM public.garment_categories
   WHERE branch_id=v_branch AND (name_en='Clothes' OR name='Clothes')
   ORDER BY created_at LIMIT 1;
  IF v_clothes IS NULL THEN
    INSERT INTO public.garment_categories(branch_id,name,name_en,sort_order,is_active)
    VALUES(v_branch,'Clothes','Clothes',1,true) RETURNING id INTO v_clothes;
  END IF;

  UPDATE public.garment_categories
     SET is_active=(id=v_clothes)
   WHERE branch_id=v_branch;

  UPDATE public.garment_types
     SET is_active=false
   WHERE branch_id=v_branch;

  UPDATE public.garment_types
     SET is_active=true,category_id=v_clothes,name='Pants',name_en='Pants',icon_key='pants'
   WHERE branch_id=v_branch AND (name_en IN ('Trousers','Pants') OR name IN ('بنطلون','Pants'));

  UPDATE public.garment_types
     SET is_active=true,category_id=v_clothes,name='Shirt',name_en='Shirt',icon_key='shirt'
   WHERE branch_id=v_branch AND (name_en='Shirt' OR name='قميص');

  UPDATE public.garment_types
     SET is_active=true,category_id=v_clothes,name='T-Shirt',name_en='T-Shirt',icon_key='shirt'
   WHERE branch_id=v_branch AND (name_en IN ('T-Shirt','T Shirt') OR name='تيشيرت');

  SELECT id INTO v_wash_iron FROM public.services
   WHERE branch_id=v_branch AND (name_en='Wash & Iron' OR name='غسيل + كي')
   ORDER BY created_at LIMIT 1;

  UPDATE public.services SET is_active=(id=v_wash_iron) WHERE branch_id=v_branch;

  UPDATE public.garment_services gs
     SET is_available=false
   WHERE gs.branch_id=v_branch;

  IF v_wash_iron IS NOT NULL THEN
    UPDATE public.garment_services gs
       SET is_available=true,
           default_price=CASE gt.name_en
             WHEN 'Pants' THEN 80
             WHEN 'Shirt' THEN 60
             WHEN 'T-Shirt' THEN 50
             ELSE gs.default_price END
      FROM public.garment_types gt
     WHERE gs.branch_id=v_branch AND gs.garment_type_id=gt.id
       AND gs.service_id=v_wash_iron AND gt.is_active=true;

    UPDATE public.service_prices sp
       SET price=CASE gt.name_en
         WHEN 'Pants' THEN 80
         WHEN 'Shirt' THEN 60
         WHEN 'T-Shirt' THEN 50
         ELSE sp.price END
      FROM public.garment_services gs
      JOIN public.garment_types gt ON gt.id=gs.garment_type_id
     WHERE sp.garment_service_id=gs.id AND sp.branch_id=v_branch
       AND gs.service_id=v_wash_iron AND gt.is_active=true
       AND sp.id IN (
         SELECT DISTINCT ON (sp2.garment_service_id) sp2.id
         FROM public.service_prices sp2
         WHERE sp2.branch_id=v_branch
         ORDER BY sp2.garment_service_id,sp2.effective_from DESC
       );
  END IF;
END $$;
