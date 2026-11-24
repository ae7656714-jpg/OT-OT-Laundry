-- OT Laundry: unified cash-flow read model and safe manual Cash In.
-- Existing invoice payments and approved expenses already post to cash_transactions.
ALTER TABLE public.cash_transactions
  ADD COLUMN IF NOT EXISTS source_type text,
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS customer_name text,
  ADD COLUMN IF NOT EXISTS related_order_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS idempotency_key text;

ALTER TABLE public.cash_transactions DROP CONSTRAINT IF EXISTS cash_transactions_transaction_type_check;
ALTER TABLE public.cash_transactions ADD CONSTRAINT cash_transactions_transaction_type_check
  CHECK (transaction_type = ANY (ARRAY[
    'opening','invoice_payment','expense','payment_reversal','transfer_in','transfer_out',
    'adjustment','salary_payment','employee_advance','advance_repayment','manual_income'
  ]));

CREATE UNIQUE INDEX IF NOT EXISTS cash_transactions_branch_idempotency_uidx
  ON public.cash_transactions(branch_id,idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.ot_laundry_enrich_cash_transaction()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.payment_id IS NOT NULL THEN
    SELECT 'order_payment', p.payment_method, i.id, i.customer_name_snapshot
      INTO NEW.source_type, NEW.payment_method, NEW.related_order_id, NEW.customer_name
    FROM public.payments p
    JOIN public.invoices i ON i.id=p.invoice_id
    WHERE p.id=NEW.payment_id AND p.branch_id=NEW.branch_id;
  ELSIF NEW.expense_id IS NOT NULL THEN
    SELECT 'expense', ec.name
      INTO NEW.source_type, NEW.category
    FROM public.expenses e
    LEFT JOIN public.expense_categories ec ON ec.id=e.category_id
    WHERE e.id=NEW.expense_id AND e.branch_id=NEW.branch_id;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS ot_laundry_enrich_cash_transaction ON public.cash_transactions;
CREATE TRIGGER ot_laundry_enrich_cash_transaction
BEFORE INSERT ON public.cash_transactions
FOR EACH ROW EXECUTE FUNCTION public.ot_laundry_enrich_cash_transaction();

CREATE OR REPLACE FUNCTION public.create_manual_cash_in(
  p_cash_account_id uuid,
  p_amount numeric,
  p_category text DEFAULT 'other_income',
  p_payment_method text DEFAULT 'cash',
  p_customer_name text DEFAULT NULL,
  p_invoice_id uuid DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_branch uuid;
  v_tx_id uuid;
  v_amount numeric(14,2);
  v_category text;
BEGIN
  IF v_uid IS NULL OR NOT private.user_has_permission('cash.manage') THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE='42501';
  END IF;
  SELECT branch_id INTO v_branch FROM public.profiles
   WHERE id=v_uid AND is_active=true;
  IF v_branch IS NULL OR NOT (v_branch IN (SELECT private.user_branch_ids())) THEN
    RAISE EXCEPTION 'BRANCH_FORBIDDEN' USING ERRCODE='42501';
  END IF;
  IF p_amount IS NULL OR p_amount<=0 OR p_amount>999999999 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE='22023';
  END IF;
  v_amount:=round(p_amount,2);
  v_category:=coalesce(p_category,'other_income');
  IF v_category NOT IN ('customer_advance','money_on_account','owner_injection','previous_balance','other_income') THEN
    RAISE EXCEPTION 'INVALID_CATEGORY' USING ERRCODE='22023';
  END IF;
  IF p_payment_method NOT IN ('cash','card','bank_transfer','wallet','other') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD' USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cash_accounts
    WHERE id=p_cash_account_id AND branch_id=v_branch AND is_active=true) THEN
    RAISE EXCEPTION 'CASH_ACCOUNT_INVALID' USING ERRCODE='22023';
  END IF;
  IF p_invoice_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM public.invoices WHERE id=p_invoice_id AND branch_id=v_branch
  ) THEN
    RAISE EXCEPTION 'ORDER_INVALID' USING ERRCODE='22023';
  END IF;
  IF p_idempotency_key IS NOT NULL AND EXISTS(
    SELECT 1 FROM public.cash_transactions WHERE branch_id=v_branch AND idempotency_key=p_idempotency_key
  ) THEN
    SELECT id INTO v_tx_id FROM public.cash_transactions
     WHERE branch_id=v_branch AND idempotency_key=p_idempotency_key LIMIT 1;
    RETURN jsonb_build_object('transaction_id',v_tx_id,'duplicate',true);
  END IF;
  INSERT INTO public.cash_transactions(
    branch_id,cash_account_id,transaction_type,direction,amount,reference,description,
    created_by,source_type,category,customer_name,related_order_id,payment_method,idempotency_key
  ) VALUES (
    v_branch,p_cash_account_id,'manual_income','in',v_amount,
    CASE WHEN p_invoice_id IS NOT NULL THEN 'ORDER-'||p_invoice_id::text ELSE NULL END,
    coalesce(nullif(trim(p_note),''),v_category),v_uid,'manual_income',v_category,
    nullif(trim(coalesce(p_customer_name,'')),''),p_invoice_id,p_payment_method,p_idempotency_key
  ) RETURNING id INTO v_tx_id;
  RETURN jsonb_build_object('transaction_id',v_tx_id,'amount',v_amount,'duplicate',false);
END; $$;

REVOKE ALL ON FUNCTION public.create_manual_cash_in(uuid,numeric,text,text,text,uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_manual_cash_in(uuid,numeric,text,text,text,uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_laundry_cash_flow(
  p_from timestamptz,
  p_to timestamptz
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,private,pg_temp AS $$
WITH branch_accounts AS (
  SELECT id, name, opening_balance
  FROM public.cash_accounts
  WHERE branch_id IN (SELECT private.user_branch_ids())
    AND private.user_has_permission('cash.view')
),
prior AS (
  SELECT coalesce(sum(CASE WHEN ct.direction='in' THEN ct.amount ELSE -ct.amount END),0) AS movement
  FROM public.cash_transactions ct
  JOIN branch_accounts a ON a.id=ct.cash_account_id
  WHERE ct.created_at < p_from
),
opening AS (
  SELECT coalesce(sum(opening_balance),0) AS amount FROM branch_accounts
),
period AS (
  SELECT ct.*, a.name AS account_name
  FROM public.cash_transactions ct
  JOIN branch_accounts a ON a.id=ct.cash_account_id
  WHERE ct.created_at >= p_from AND ct.created_at < p_to
),
totals AS (
  SELECT
    coalesce(sum(amount) FILTER (WHERE direction='in' AND transaction_type NOT IN ('transfer_in')),0) AS cash_in,
    coalesce(sum(amount) FILTER (WHERE direction='out' AND transaction_type NOT IN ('transfer_out')),0) AS cash_out,
    coalesce(sum(CASE WHEN direction='in' THEN amount ELSE -amount END),0) AS net_movement
  FROM period
)
SELECT jsonb_build_object(
  'opening_balance',(SELECT amount FROM opening)+(SELECT movement FROM prior),
  'cash_in',(SELECT cash_in FROM totals),
  'cash_out',(SELECT cash_out FROM totals),
  'net_cash',(SELECT cash_in-cash_out FROM totals),
  'closing_balance',(SELECT amount FROM opening)+(SELECT movement FROM prior)+(SELECT net_movement FROM totals),
  'transactions',coalesce((SELECT jsonb_agg(
    jsonb_build_object(
      'id',p.id,'cash_account_id',p.cash_account_id,'account_name',p.account_name,
      'transaction_type',p.transaction_type,'direction',p.direction,'amount',p.amount,
      'reference',p.reference,'description',p.description,'created_at',p.created_at,
      'source_type',p.source_type,'category',p.category,'customer_name',p.customer_name,
      'related_order_id',p.related_order_id,'payment_method',p.payment_method
    ) ORDER BY p.created_at DESC
  ) FROM period p),'[]'::jsonb)
);
$$;

REVOKE ALL ON FUNCTION public.get_laundry_cash_flow(timestamptz,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_laundry_cash_flow(timestamptz,timestamptz) TO authenticated;
