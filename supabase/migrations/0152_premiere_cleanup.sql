-- 0152: Premiere cleanup hardening (review of phase 6, 2026-11-02).
--
-- stream_deletions  every Stream video id that leaves event_films (replaced,
--                   deleted, or the row cascaded away with its event) is
--                   queued here by trigger; premiere-webhook's sweep deletes
--                   them from Stream. Nothing can orphan a video any more.
-- event_films.over_at  when the sweep first saw the show over (ended,
--                   cancelled, removed, or a week past its start without going
--                   live). The deletion date counts from this, not from
--                   events.ended_at, which the host can edit.

create table public.stream_deletions (
  uid       text primary key,
  queued_at timestamptz not null default now(),
  attempts  int not null default 0
);
alter table public.stream_deletions enable row level security;
revoke all on public.stream_deletions from anon, authenticated;

alter table public.event_films add column over_at timestamptz;

create or replace function public.event_films_queue_stream_deletions()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    insert into stream_deletions (uid)
      select u from unnest(array[old.film_uid, old.trailer_uid]) u where u is not null
      on conflict do nothing;
    return old;
  end if;
  insert into stream_deletions (uid)
    select u from unnest(array[
      case when old.film_uid is distinct from new.film_uid then old.film_uid end,
      case when old.trailer_uid is distinct from new.trailer_uid then old.trailer_uid end
    ]) u where u is not null
    on conflict do nothing;
  return new;
end $$;

create trigger event_films_stream_deletions
  after update of film_uid, trailer_uid or delete on public.event_films
  for each row execute function public.event_films_queue_stream_deletions();
