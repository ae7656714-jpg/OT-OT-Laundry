-- Targeted indexes for dashboard synchronization and Cash Flow history.
CREATE INDEX IF NOT EXISTS idx_cash_transactions_branch_created_at
  ON public.cash_transactions(branch_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_transactions_related_order
  ON public.cash_transactions(related_order_id);
CREATE INDEX IF NOT EXISTS idx_invoices_branch_received_at
  ON public.invoices(branch_id,received_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_branch_delivered_at
  ON public.invoices(branch_id,delivered_at DESC)
  WHERE status='delivered';
