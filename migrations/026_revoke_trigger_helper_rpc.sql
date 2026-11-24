-- Trigger-only helper must not be callable as a public RPC.
REVOKE ALL ON FUNCTION public.ot_laundry_enrich_cash_transaction() FROM PUBLIC, anon, authenticated;
