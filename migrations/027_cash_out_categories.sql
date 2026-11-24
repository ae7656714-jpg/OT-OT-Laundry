-- Friendly default Cash Out categories for the empty demo branch.
INSERT INTO public.expense_categories(branch_id,name,is_active)
SELECT b.id, v.name, true
FROM public.branches b
CROSS JOIN (VALUES
  ('Supplies'),('Detergents'),('Packaging'),('Electricity'),('Water'),
  ('Rent'),('Salary'),('Maintenance'),('Transportation'),('Other Expense')
) AS v(name)
WHERE b.code='MAIN'
  AND NOT EXISTS (
    SELECT 1 FROM public.expense_categories ec
    WHERE ec.branch_id=b.id AND lower(ec.name)=lower(v.name)
  );
