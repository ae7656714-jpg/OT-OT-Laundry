-- OT Laundry bilingual catalog seed (idempotent).
-- Prices intentionally remain NULL until the laundry owner enters them.
ALTER TABLE public.garment_categories ADD COLUMN IF NOT EXISTS name_en text;
ALTER TABLE public.garment_types ADD COLUMN IF NOT EXISTS name_en text;
ALTER TABLE public.services ADD COLUMN IF NOT EXISTS name_en text;
ALTER TABLE public.garment_services ALTER COLUMN default_price DROP NOT NULL;
ALTER TABLE public.garment_services ALTER COLUMN default_price DROP DEFAULT;

UPDATE public.garment_categories SET name='أخرى', name_en='Other' WHERE name='أخري';
UPDATE public.garment_categories SET name_en = CASE name
  WHEN 'رجالي' THEN 'Men' WHEN 'حريمي' THEN 'Women'
  WHEN 'أطفالي' THEN 'Children' WHEN 'أخري' THEN 'Other' WHEN 'أخرى' THEN 'Other'
  ELSE coalesce(name_en, name) END;
UPDATE public.garment_types SET name_en='Shirt' WHERE name='قميص' AND name_en IS NULL;
UPDATE public.services SET name_en = CASE name
  WHEN 'غسيل' THEN 'Washing' WHEN 'كي' THEN 'Ironing'
  WHEN 'غسيل + كي' THEN 'Wash & Iron' ELSE coalesce(name_en,name) END;

INSERT INTO public.services(branch_id,name,name_en,description,sort_order,is_active)
SELECT b.id,v.name_ar,v.name_en,v.description,v.sort_order,true
FROM public.branches b
CROSS JOIN (VALUES
 ('تنظيف جاف','Dry Cleaning','تنظيف القطع التي تتطلب عناية خاصة',4),
 ('إزالة بقع','Stain Removal','معالجة البقع حسب نوع القماش',5),
 ('كي بالبخار','Steam Pressing','كي بالبخار للقطع المناسبة',6)
) AS v(name_ar,name_en,description,sort_order)
WHERE b.code='MAIN' AND NOT EXISTS(
 SELECT 1 FROM public.services s WHERE s.branch_id=b.id AND s.name=v.name_ar
);

WITH catalog(category_name,name_ar,name_en,icon_key,sort_order) AS (VALUES
 ('رجالي','هودي','Hoodie','shirt',1),('رجالي','قميص','Shirt','shirt',2),
 ('رجالي','تيشيرت','T-Shirt','shirt',3),('رجالي','بولو','Polo Shirt','shirt',4),
 ('رجالي','بنطلون جبردين','Gabardine Trousers','pants',5),('رجالي','بنطلون جينز','Jeans','pants',6),
 ('رجالي','بنطلون قماش','Dress Trousers','pants',7),('رجالي','بنطلون رياضي','Sweatpants','pants',8),
 ('رجالي','شورت','Shorts','pants',9),('رجالي','بدلة 3 قطع','Three-Piece Suit','suit',10),
 ('رجالي','بدلة 4 قطع','Four-Piece Suit','suit',11),('رجالي','جاكيت','Jacket','jacket',12),
 ('رجالي','بالطو','Overcoat','coat',13),('رجالي','صديري','Vest','vest',14),
 ('رجالي','جلابية','Galabeya','shirt',15),('رجالي','ترينج رياضي','Tracksuit','shirt',16),
 ('رجالي','سويت شيرت','Sweatshirt','shirt',17),('رجالي','كرافتة','Tie','tie',18),
 ('حريمي','بلوزة','Blouse','shirt',1),('حريمي','قميص حريمي','Women''s Shirt','shirt',2),
 ('حريمي','تيشيرت حريمي','Women''s T-Shirt','shirt',3),('حريمي','فستان','Dress','dress',4),
 ('حريمي','فستان سهرة','Evening Dress','dress',5),('حريمي','جيبة','Skirt','skirt',6),
 ('حريمي','بنطلون حريمي','Women''s Trousers','pants',7),('حريمي','بنطلون جينز حريمي','Women''s Jeans','pants',8),
 ('حريمي','عباية','Abaya','dress',9),('حريمي','عباية صلاة','Prayer Abaya','dress',10),
 ('حريمي','جاكيت حريمي','Women''s Jacket','jacket',11),('حريمي','بالطو حريمي','Women''s Coat','coat',12),
 ('حريمي','كارديجان','Cardigan','shirt',13),('حريمي','بلوفر','Sweater','shirt',14),
 ('حريمي','هودي حريمي','Women''s Hoodie','shirt',15),('حريمي','بيجامة','Pajama Set','shirt',16),
 ('حريمي','طقم حريمي','Women''s Two-Piece Set','shirt',17),('حريمي','طرحة','Hijab','scarf',18),
 ('حريمي','إيشارب','Scarf','scarf',19),('حريمي','شال','Shawl','scarf',20),
 ('حريمي','ملابس رياضية حريمي','Women''s Activewear','shirt',21),
 ('أطفالي','تيشيرت أطفال','Kids'' T-Shirt','shirt',1),('أطفالي','قميص أطفال','Kids'' Shirt','shirt',2),
 ('أطفالي','بنطلون أطفال','Kids'' Trousers','pants',3),('أطفالي','فستان أطفال','Kids'' Dress','dress',4),
 ('أطفالي','بيجامة أطفال','Kids'' Pajamas','shirt',5),('أطفالي','جاكيت أطفال','Kids'' Jacket','jacket',6),
 ('أطفالي','هودي أطفال','Kids'' Hoodie','shirt',7),('أطفالي','شورت أطفال','Kids'' Shorts','pants',8),
 ('أطفالي','زي مدرسي','School Uniform','shirt',9),
 ('أخرى','ملاية سرير','Bedsheet','linen',1),('أخرى','كيس مخدة','Pillowcase','linen',2),
 ('أخرى','بطانية','Blanket','linen',3),('أخرى','لحاف','Duvet','linen',4),
 ('أخرى','ستارة','Curtain','linen',5),('أخرى','مفرش','Tablecloth','linen',6),
 ('أخرى','فوطة','Towel','linen',7)
)
INSERT INTO public.garment_types(branch_id,category_id,name,name_en,icon_key,sort_order,is_active)
SELECT b.id,gc.id,c.name_ar,c.name_en,c.icon_key,c.sort_order,true
FROM catalog c
JOIN public.branches b ON b.code='MAIN'
JOIN public.garment_categories gc ON gc.branch_id=b.id AND gc.name=c.category_name
WHERE NOT EXISTS(SELECT 1 FROM public.garment_types gt
 WHERE gt.branch_id=b.id AND gt.category_id=gc.id AND gt.name=c.name_ar);

-- Every active garment is offered each active laundry service; no prices are invented.
INSERT INTO public.garment_services(branch_id,garment_type_id,service_id,default_price,is_available)
SELECT b.id,gt.id,s.id,NULL,true
FROM public.branches b
JOIN public.garment_types gt ON gt.branch_id=b.id AND gt.is_active=true
JOIN public.services s ON s.branch_id=b.id AND s.is_active=true
WHERE b.code='MAIN' AND NOT EXISTS(SELECT 1 FROM public.garment_services gs
 WHERE gs.branch_id=b.id AND gs.garment_type_id=gt.id AND gs.service_id=s.id);
