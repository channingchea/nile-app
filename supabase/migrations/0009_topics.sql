-- Topic model: curated flat taxonomy, event tags (consumer side), and user
-- interests with a 1–3 weight from the onboarding bubble picker. The weight
-- drives recommend_events_by_topic ranking. `source` distinguishes explicit
-- picks from a future inferred-affinity job (same tables, no rework).

-- ── Tables ───────────────────────────────────────────────────────────────────

-- Controlled vocabulary. Flat (no parent_id). Seeded below; curated via SQL.
create table public.topics (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,            -- 'hip-hop', 'comedy'
  name        text not null,                   -- 'Hip-Hop', 'Comedy'
  sort_order  int  not null default 0,         -- controls bubble layout order
  is_active   boolean not null default true,   -- hide without deleting
  created_at  timestamptz not null default now()
);

-- Event ↔ topic tags. Without these, user interests have nothing to match.
create table public.event_topics (
  event_id  uuid not null references public.events(id) on delete cascade,
  topic_id  uuid not null references public.topics(id) on delete cascade,
  primary key (event_id, topic_id)
);

-- User ↔ topic interests. weight = bubble size from the picker.
create table public.user_topics (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  topic_id   uuid not null references public.topics(id) on delete cascade,
  weight     int  not null default 1 check (weight between 1 and 3),
  source     text not null default 'explicit'
             check (source in ('explicit','inferred')),
  updated_at timestamptz not null default now(),
  primary key (user_id, topic_id)
);

create index event_topics_topic_idx on public.event_topics (topic_id);
create index user_topics_user_idx   on public.user_topics (user_id);

-- ── RLS ──────────────────────────────────────────────────────────────────────

alter table public.topics       enable row level security;
alter table public.event_topics enable row level security;
alter table public.user_topics  enable row level security;

-- topics: public read, no client writes (seeded/curated server-side).
create policy "topics: public read"
  on public.topics for select using (true);

-- event_topics: public read; only the event's host may tag/untag.
create policy "event_topics: public read"
  on public.event_topics for select using (true);
create policy "event_topics: host insert"
  on public.event_topics for insert with check (
    auth.uid() = (select host_id from public.events where id = event_id)
  );
create policy "event_topics: host delete"
  on public.event_topics for delete using (
    auth.uid() = (select host_id from public.events where id = event_id)
  );

-- user_topics: public read (interests aren't secret; recs may need them);
-- writes own-only.
create policy "user_topics: public read"
  on public.user_topics for select using (true);
create policy "user_topics: insert own"
  on public.user_topics for insert with check (auth.uid() = user_id);
create policy "user_topics: update own"
  on public.user_topics for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "user_topics: delete own"
  on public.user_topics for delete using (auth.uid() = user_id);

-- ── Seed ─────────────────────────────────────────────────────────────────────

insert into public.topics (slug, name, sort_order) values
  ('hip-hop',     'Hip-Hop',      1),
  ('rnb',         'R&B',          2),
  ('house-edm',   'House / EDM',  3),
  ('dj-sets',     'DJ Sets',      4),
  ('live-bands',  'Live Bands',   5),
  ('jazz',        'Jazz',         6),
  ('afrobeats',   'Afrobeats',    7),
  ('latin',       'Latin',        8),
  ('comedy',      'Comedy',       9),
  ('talk',        'Talk / Podcast', 10),
  ('gaming',      'Gaming',       11),
  ('sports',      'Sports Watch', 12),
  ('tech',        'Tech Talks',   13),
  ('cooking',     'Cooking',      14),
  ('fitness',     'Fitness',      15),
  ('fashion',     'Fashion',      16),
  ('art',         'Art',          17),
  ('faith',       'Faith',        18),
  ('qa-ama',      'Q&A / AMA',    19),
  ('open-mic',    'Open Mic',     20);

-- ── Recommendation RPC ───────────────────────────────────────────────────────
-- Events in topics the caller cares about, ranked by summed bubble weight.
-- SECURITY INVOKER like recommend_events_from_network (0003), so events RLS
-- applies. Excludes own + blocked hosts to mirror the network recs.

create or replace function public.recommend_events_by_topic(
  page_limit int default 20
)
returns setof events
language sql
stable
set search_path = public
as $$
  select e.*
  from events e
  join event_topics et on et.event_id = e.id
  join user_topics  ut on ut.topic_id = et.topic_id
                      and ut.user_id  = auth.uid()
  where e.status in ('scheduled', 'live')
    and e.host_id <> auth.uid()
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = e.host_id)
         or (b.blocked_id = auth.uid() and b.blocker_id = e.host_id)
    )
  group by e.id
  order by sum(ut.weight) desc, e.scheduled_at asc nulls last
  limit page_limit;
$$;
