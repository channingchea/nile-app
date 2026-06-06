-- Roadmap #6 (events): event reposts + share-event-via-DM. Mirrors 0006_sharing.

-- ── event_reposts ──────────────────────────────────────────────────────────────
create table if not exists event_reposts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  event_id   uuid not null references events(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, event_id)
);
create index if not exists event_reposts_event_idx on event_reposts (event_id);
create index if not exists event_reposts_user_created_idx
  on event_reposts (user_id, created_at desc);

alter table event_reposts enable row level security;
drop policy if exists "event_reposts_select_all" on event_reposts;
drop policy if exists "event_reposts_insert_own" on event_reposts;
drop policy if exists "event_reposts_delete_own" on event_reposts;
create policy "event_reposts_select_all" on event_reposts for select using (true);
create policy "event_reposts_insert_own" on event_reposts for insert with check (user_id = auth.uid());
create policy "event_reposts_delete_own" on event_reposts for delete using (user_id = auth.uid());

-- ── events.repost_count + trigger ──────────────────────────────────────────────
alter table events add column if not exists repost_count int not null default 0;

create or replace function bump_event_repost_count()
returns trigger language plpgsql security definer as $$
begin
  if (tg_op = 'INSERT') then
    update events set repost_count = repost_count + 1 where id = new.event_id;
  elsif (tg_op = 'DELETE') then
    update events set repost_count = greatest(0, repost_count - 1) where id = old.event_id;
  end if;
  return null;
end;
$$;

drop trigger if exists event_reposts_count_ins on event_reposts;
drop trigger if exists event_reposts_count_del on event_reposts;
create trigger event_reposts_count_ins after insert on event_reposts
  for each row execute function bump_event_repost_count();
create trigger event_reposts_count_del after delete on event_reposts
  for each row execute function bump_event_repost_count();

update events
  set repost_count = coalesce(
    (select count(*) from event_reposts where event_reposts.event_id = events.id), 0);

-- ── messages.shared_event_id (share an event via DM) ───────────────────────────
alter table messages
  add column if not exists shared_event_id uuid references events(id) on delete set null;
