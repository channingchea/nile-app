-- Ad platform — Phase A-4 Part 1: standalone external-advertiser ads.
-- Adds brand accounts (separate from social profiles), self-uploaded creatives
-- (image + headline + body + external click-through URL), and topic targeting.
-- Unlike A-1/A-2 (which boost an existing event/post), a standalone ad references
-- neither — so this migration relaxes ad_campaigns' advertiser_id NOT NULL and the
-- one_target CHECK. Part 1 ships schema + serving; campaigns are seeded manually
-- (the self-serve portal + paid path land in Part 2). Review states
-- ('pending_review','paused') already exist in the status CHECK from 0025.

-- ── Advertiser accounts ──────────────────────────────────────────────────────
-- A brand's portal login, distinct from the social `profiles` table. One auth
-- user per account in v1 (a members table is deferred). `profile_id` optionally
-- links/claims a Nile profile now or later — null until claimed.
create table public.advertiser_accounts (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid not null references auth.users(id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 80),
  contact_email text not null,
  profile_id    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create unique index advertiser_accounts_auth_user_idx
  on public.advertiser_accounts (auth_user_id);

-- ── ad_campaigns: support standalone (creative-only) campaigns ────────────────
-- Standalone campaigns set advertiser_account_id and leave advertiser_id null;
-- legacy host boosts keep advertiser_id (a profile). Relax one_target so a
-- creative-only campaign can have zero event/post; serving requires an attached
-- ad_creatives row to identify a valid standalone ad.
alter table public.ad_campaigns
  add column advertiser_account_id uuid references public.advertiser_accounts(id) on delete cascade;
alter table public.ad_campaigns
  alter column advertiser_id drop not null;
alter table public.ad_campaigns
  drop constraint ad_campaigns_one_target;
alter table public.ad_campaigns
  add constraint ad_campaigns_one_target check (num_nonnulls(event_id, post_id) <= 1);
-- Every campaign must be owned by exactly one of: a profile (host boost) or an
-- advertiser account (standalone). Prevents orphan rows now that both are nullable.
alter table public.ad_campaigns
  add constraint ad_campaigns_one_owner
  check (num_nonnulls(advertiser_id, advertiser_account_id) = 1);

-- ── Creatives ────────────────────────────────────────────────────────────────
-- Self-uploaded standalone creative. One per campaign in v1.
create table public.ad_creatives (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null unique references public.ad_campaigns(id) on delete cascade,
  image_url   text not null,
  headline    text not null check (char_length(headline) between 1 and 80),
  body        text not null check (char_length(body) between 1 and 200),
  click_url   text not null check (click_url ~* '^https://'),
  created_at  timestamptz not null default now()
);

-- ── Targeting ────────────────────────────────────────────────────────────────
-- Topic-only in v1; geo/age columns added nullable for later. An empty/absent
-- topic_ids means the campaign serves broadly (no topic filter).
create table public.ad_targeting (
  campaign_id uuid primary key references public.ad_campaigns(id) on delete cascade,
  topic_ids   uuid[] not null default '{}',
  geo         text[],
  min_age     int,
  max_age     int
);

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table public.advertiser_accounts enable row level security;
alter table public.ad_creatives        enable row level security;
alter table public.ad_targeting        enable row level security;

-- advertiser_accounts: an owner reads/updates only their own account.
create policy "advertiser_accounts: read own"
  on public.advertiser_accounts for select using (auth.uid() = auth_user_id);
create policy "advertiser_accounts: insert own"
  on public.advertiser_accounts for insert with check (auth.uid() = auth_user_id);
create policy "advertiser_accounts: update own"
  on public.advertiser_accounts for update using (auth.uid() = auth_user_id)
  with check (auth.uid() = auth_user_id);

-- ad_creatives / ad_targeting: scoped to the owning advertiser account. Serving
-- reads happen through get_feed_ads (SECURITY DEFINER), so no public read.
create policy "ad_creatives: read own"
  on public.ad_creatives for select using (
    exists (
      select 1 from public.ad_campaigns c
      join public.advertiser_accounts a on a.id = c.advertiser_account_id
      where c.id = ad_creatives.campaign_id and a.auth_user_id = auth.uid()
    )
  );
create policy "ad_creatives: insert own"
  on public.ad_creatives for insert with check (
    exists (
      select 1 from public.ad_campaigns c
      join public.advertiser_accounts a on a.id = c.advertiser_account_id
      where c.id = ad_creatives.campaign_id and a.auth_user_id = auth.uid()
    )
  );
create policy "ad_targeting: read own"
  on public.ad_targeting for select using (
    exists (
      select 1 from public.ad_campaigns c
      join public.advertiser_accounts a on a.id = c.advertiser_account_id
      where c.id = ad_targeting.campaign_id and a.auth_user_id = auth.uid()
    )
  );
create policy "ad_targeting: insert own"
  on public.ad_targeting for insert with check (
    exists (
      select 1 from public.ad_campaigns c
      join public.advertiser_accounts a on a.id = c.advertiser_account_id
      where c.id = ad_targeting.campaign_id and a.auth_user_id = auth.uid()
    )
  );

-- ── Storage bucket for brand creative images ─────────────────────────────────
-- Public-read (images render in-feed); writes go through the portal/service role.
insert into storage.buckets (id, name, public)
values ('ad-creatives', 'ad-creatives', true)
on conflict (id) do nothing;

create policy "ad-creatives: public read"
  on storage.objects for select using (bucket_id = 'ad-creatives');
