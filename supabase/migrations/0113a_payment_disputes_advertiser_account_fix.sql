-- 0113a — history marker, deliberately near-empty.
--
-- 0113 first shipped joining advertiser_accounts on ad_campaigns.advertiser_id.
-- Wrong column: advertiser_id → profiles (the user who bought a host boost),
-- advertiser_account_id → advertiser_accounts (the self-serve brand). The join
-- matched nothing, so a chargeback recorded no payer and never demoted the
-- brand's trust tier. Caught in prod smoke-testing before any real dispute
-- existed; 0113a re-created open_payment_dispute / close_payment_dispute with
-- the right column.
--
-- The fix has since been folded back into 0113 itself, so a rebuild from these
-- files is correct without this file doing anything. It stays so that the local
-- migration list matches the remote history. The revokes below are the only
-- statements, and they are idempotent.

revoke execute on function public.open_payment_dispute(text, text, text, integer, text, text)
  from public, anon, authenticated;
revoke execute on function public.close_payment_dispute(text, text, text)
  from public, anon, authenticated;
