-- Ad platform — Phase A-4 Part 1 follow-up: viewer feedback on standalone ads.
-- Lets a viewer report an ad or mark it "not interested" from the in-feed card.
--   • Reporting reuses the Phase 19 reports table; add 'ad' to report_target_type
--     so target_id can reference an ad_campaigns row.
--   • "Not interested" is a soft signal logged as an ad_events row (insert-only,
--     same RLS as impression/click), so add 'not_interested' to the kind CHECK.
--     It does not bill or affect spend — tally_ad_spend only counts impression/click.

alter type public.report_target_type add value if not exists 'ad';

alter table public.ad_events drop constraint ad_events_kind_check;
alter table public.ad_events add constraint ad_events_kind_check
  check (kind in ('impression', 'click', 'not_interested'));
