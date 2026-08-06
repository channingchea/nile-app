-- 0080: Event Sponsorship — advertiser dashboard support (plan Phase 3).
--
-- get_advertiser_performance gains placement + the sponsored event's title and
-- date, so the portal can render sponsorship rows ("Sponsor an event" product)
-- distinctly: event name, event date, and lobby impressions/clicks (ad_events
-- is placement-agnostic — lobby impressions/clicks are already counted here).

drop function public.get_advertiser_performance(uuid, integer, timestamptz); -- return type change

create function public.get_advertiser_performance(
  p_account_id uuid,
  p_limit      integer     default 15,
  p_before     timestamptz default null   -- keyset cursor: created_at of last row
)
returns table (
  campaign_id        uuid,
  name               text,
  headline           text,
  status             text,
  budget_cents       integer,
  spent_cents        integer,
  starts_at          timestamptz,
  ends_at            timestamptz,
  impressions        bigint,
  clicks             bigint,
  review_note        text,
  created_at         timestamptz,
  placement          text,
  event_title        text,
  event_scheduled_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id, c.name, cr.headline, c.status, c.budget_cents, c.spent_cents,
    c.starts_at, c.ends_at,
    count(ae.*) filter (where ae.kind = 'impression') as impressions,
    count(ae.*) filter (where ae.kind = 'click')      as clicks,
    c.review_note, c.created_at,
    c.placement, e.title, e.scheduled_at
  from ad_campaigns c
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()          -- caller must own the account
  left join ad_creatives cr on cr.campaign_id = c.id
  left join ad_events    ae on ae.campaign_id = c.id
  left join events       e  on e.id = c.event_id
  where c.advertiser_account_id = p_account_id
    and (p_before is null or c.created_at < p_before)
  group by c.id, cr.headline, e.title, e.scheduled_at
  order by c.created_at desc
  limit greatest(1, least(p_limit, 100));
$$;
grant execute on function public.get_advertiser_performance(uuid, integer, timestamptz) to authenticated;
