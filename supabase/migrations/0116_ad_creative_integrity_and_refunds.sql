-- 0116 — P2 #22, #23 and #25 from the 2026-08-16 platform review.
--
-- #22 An approved creative could be swapped for anything. 0038 let the portal
--     UPDATE ad_creatives directly while the campaign is pending_review, which
--     is the right feature — but the check was ownership + status and nothing
--     else. validateCreative (create-ad-payment) is the ONLY place that
--     enforces "the asset must live in our bucket, under your folder", and a
--     direct PostgREST PATCH never goes near it. image_url had no constraint at
--     any layer. So: submit clean art hosted on your own CDN, pass review, then
--     swap the bytes at origin — forever, invisibly.
--
-- #23 A live policy-violating ad could be paused but never killed. There was no
--     active → rejected transition at all, so the campaign stayed non-terminal,
--     no money went back, and the reports queue's "Reject" button 409'd on
--     exactly the ads that most needed it.
--
-- #25 An advertiser could not stop their own live campaign or see a receipt.
--     A brand hitting a PR crisis on day two of a fourteen-day flight had to
--     email us.
--
-- #23 and #25 are the same machinery pointed at two different people, and both
-- became possible only after 0115: spend now tracks delivery, so
-- budget - spent is a defensible refund rather than a guess.

-- ── #22 · the asset is not the advertiser's to change ───────────────────────
-- Two layers, on purpose. The CHECK is absolute — it binds the service role and
-- any future edge function too, so a bug upstream can't land an off-bucket URL.
-- The trigger is the per-account half a CHECK can't express.
--
-- The project URL is hard-coded because a CHECK cannot read a setting; the same
-- literal is already hard-coded in 0106's cron job.
alter table public.ad_creatives
  drop constraint if exists ad_creatives_image_url_bucket;
alter table public.ad_creatives
  add constraint ad_creatives_image_url_bucket check (
    image_url is null
    or image_url like
       'https://jelmkkvyrliywcdkzhuu.supabase.co/storage/v1/object/public/ad-creatives/%'
  );

create or replace function public.protect_ad_creative()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account uuid;
  v_prefix  text;
begin
  -- Service role and admins are trusted here: review-ad-campaign and
  -- create-ad-payment already validate, and an admin editing a creative is a
  -- moderation action, not an advertiser action.
  --
  -- Note the consequence, since it is easy to miss in testing: an admin who
  -- also owns an advertiser account is exempt from the per-account rule below.
  -- The CHECK constraint above still binds them to our bucket, and an admin is
  -- already trusted with every moderation lever there is, so this is the same
  -- trust boundary 0101 draws everywhere else.
  if not public.client_role_blocked() then
    return new;
  end if;

  -- The reviewed artifact for a video ad is the file itself. The portal already
  -- tells advertisers that replacing a video means withdrawing and
  -- resubmitting; this makes that true rather than merely stated.
  new.kind        := old.kind;
  new.video_path  := old.video_path;
  new.thumb_path  := old.thumb_path;
  new.duration_ms := old.duration_ms;

  -- An image CAN still be replaced in review — that is a real part of the edit
  -- flow — but only with something the advertiser actually uploaded to their
  -- own folder in our bucket.
  if new.image_url is distinct from old.image_url then
    select c.advertiser_account_id into v_account
      from ad_campaigns c where c.id = new.campaign_id;
    v_prefix := 'https://jelmkkvyrliywcdkzhuu.supabase.co/storage/v1/object/public/ad-creatives/'
                || coalesce(v_account::text, '-') || '/';
    if v_account is null
       or new.image_url is null
       or left(new.image_url, length(v_prefix)) <> v_prefix then
      raise exception 'Creative image must be uploaded through the portal';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.protect_ad_creative() from public, anon, authenticated;

drop trigger if exists ad_creatives_protect on public.ad_creatives;
create trigger ad_creatives_protect
  before update on public.ad_creatives
  for each row
  execute function public.protect_ad_creative();

-- ── #22 · the TOCTOU on approve ─────────────────────────────────────────────
-- The advertiser can edit headline and click_url while the admin's review modal
-- is open, so the admin approves copy they never read. The portal now sends the
-- updated_at it rendered from, and review-ad-campaign refuses the approve if it
-- has moved. Nothing to hash: the timestamp is the fingerprint.
alter table public.ad_creatives
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.touch_ad_creative()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists ad_creatives_touch on public.ad_creatives;
-- Fires after ad_creatives_protect (alphabetical order among BEFORE triggers:
-- "protect" then "touch"), so it stamps the row the protector has already
-- corrected.
create trigger ad_creatives_touch
  before update on public.ad_creatives
  for each row
  execute function public.touch_ad_creative();

-- ── #23 / #25 · what came back, and why ─────────────────────────────────────
-- Refunds had no home. review-ad-campaign issued them to Stripe and nothing in
-- Postgres remembered, so the portal could never show a receipt and nobody
-- could answer "what did this campaign actually cost".
create table if not exists public.ad_refunds (
  id                uuid primary key default gen_random_uuid(),
  campaign_id       uuid not null references public.ad_campaigns(id) on delete cascade,
  stripe_refund_id  text unique,
  payment_intent_id text,
  amount_cents      integer not null check (amount_cents >= 0),
  -- Who pulled the trigger and why. 'killed' is ours, 'stopped' is theirs.
  reason            text not null check (reason in ('killed', 'stopped', 'withdrawn', 'other')),
  note              text,
  actor_id          uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now()
);

create index if not exists ad_refunds_campaign_idx on public.ad_refunds (campaign_id);

alter table public.ad_refunds enable row level security;

-- Advertisers read their own; admins read everything. Every write is service
-- role, so there is no insert/update/delete policy.
drop policy if exists ad_refunds_select_own on public.ad_refunds;
create policy ad_refunds_select_own on public.ad_refunds
  for select using (
    public.is_admin()
    or exists (
      select 1
        from ad_campaigns c
        join advertiser_accounts a on a.id = c.advertiser_account_id
       where c.id = ad_refunds.campaign_id
         and a.auth_user_id = (select auth.uid())
    )
  );

grant select on public.ad_refunds to authenticated;

-- Distinguishes "the advertiser stopped this" from "it ran its course", without
-- inventing a status that every check constraint and every UI branch would have
-- to learn. Both end as 'completed'.
alter table public.ad_campaigns
  add column if not exists stopped_at timestamptz;

-- ── #25 · the receipt ───────────────────────────────────────────────────────
-- One row per campaign that ever took money, with what was charged, what was
-- earned against it, and what came back. SECURITY DEFINER and scoped to the
-- caller's own account — ad_campaigns is not client-readable.
create or replace function public.get_advertiser_receipts(
  p_account_id uuid,
  p_limit      integer default 50
)
returns table (
  campaign_id      uuid,
  name             text,
  placement        text,
  status           text,
  event_title      text,
  charged_at       timestamptz,
  budget_cents     integer,
  spent_cents      integer,
  refunded_cents   bigint,
  net_cents        bigint,
  stopped_at       timestamptz,
  payment_intent   text,
  starts_at        timestamptz,
  ends_at          timestamptz
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select
    c.id, c.name, c.placement, c.status, e.title,
    c.created_at,
    c.budget_cents,
    c.spent_cents,
    coalesce(r.refunded, 0)::bigint,
    greatest(c.budget_cents - coalesce(r.refunded, 0), 0)::bigint,
    c.stopped_at,
    c.stripe_payment_intent_id,
    c.starts_at, c.ends_at
  from ad_campaigns c
  left join events e on e.id = c.event_id
  left join lateral (
    select sum(amount_cents) as refunded
      from ad_refunds f where f.campaign_id = c.id
  ) r on true
  where c.advertiser_account_id = p_account_id
    -- Only campaigns that actually took money. A pending_payment row is a
    -- half-finished checkout, not a line on a statement.
    and c.stripe_payment_intent_id is not null
    and c.status not in ('pending_payment', 'pending_review', 'pending_host')
    and exists (
      select 1 from advertiser_accounts a
       where a.id = p_account_id and a.auth_user_id = (select auth.uid())
    )
  order by c.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$function$;

revoke execute on function public.get_advertiser_receipts(uuid, integer) from public, anon;
grant  execute on function public.get_advertiser_receipts(uuid, integer) to authenticated;
