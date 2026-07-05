-- VOD pricing, part 2 (Phase 2 of the streaming audit plan).
--
-- Replays no longer publish instantly at the live-ticket gate. When a replay
-- finishes processing, the HOST gets a 'replay_price_prompt' notification and
-- the replay stays hidden from fans until the host publishes it with a price
-- (publish_replay RPC), or the 48h auto-publish cron publishes it at the live
-- price (free event → free). Fans are only fanned-out replay_ready AFTER
-- publish. Access rule: live-ticket holders always watch free; everyone else
-- needs a replay purchase (tickets.kind = 'replay') unless replay_price = 0.

-- ── events: replay price + publish stamp ──────────────────────────────────────

alter table events
  add column if not exists replay_price int
    check (replay_price is null or replay_price between 0 and 50000),
  add column if not exists replay_published_at timestamptz;

-- ── tickets: kind (live | replay) ─────────────────────────────────────────────
-- One row per (event, buyer) stays the invariant — kind records which product
-- was bought. A live holder never needs a replay row (live always unlocks the
-- replay); a replay buyer gets a 'replay' row through the same checkout path.

alter table tickets
  add column if not exists kind text not null default 'live'
    check (kind in ('live', 'replay'));

-- ── Preference column + notif_enabled ─────────────────────────────────────────

alter table notification_preferences
  add column if not exists replay_price_prompt boolean not null default true;

create or replace function notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
      when 'post_like'           then post_like
      when 'post_comment'        then post_comment
      when 'follow'              then follow
      when 'event_starting'      then event_starting
      when 'event_live'          then event_live
      when 'event_ended'         then event_ended
      when 'operator_assigned'   then operator_assigned
      when 'new_message'         then new_message
      when 'message_reaction'    then message_reaction
      when 'replay_ready'        then replay_ready
      when 'tip_received'        then tip_received
      when 'soundcheck_open'     then soundcheck_open
      when 'replay_price_prompt' then replay_price_prompt
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- Dedupe: one price prompt per (host, event), tolerant of webhook redelivery.
create unique index if not exists notifications_replay_price_prompt_uniq
  on notifications (recipient_id, entity_id)
  where type = 'replay_price_prompt';

-- ── notify_replay_ready: now prompts the HOST instead of fanning out ──────────
-- Called by livekit-webhook when egress finalizes. Fan-out to fans moves to
-- publish time (fanout_replay_ready below). Signature unchanged so the webhook
-- needs no matching redeploy to stay correct (it just changes behavior).

create or replace function notify_replay_ready(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
  v_published timestamptz;
begin
  select host_id, replay_published_at into v_host_id, v_published
    from events where id = p_event_id;
  if v_host_id is null then
    return;
  end if;

  -- Already published (e.g. re-processed egress after auto-publish): fans were
  -- (or will be) notified at publish; nothing to prompt.
  if v_published is not null then
    return;
  end if;

  insert into notifications (recipient_id, actor_id, type, entity_id)
  select v_host_id, v_host_id, 'replay_price_prompt', p_event_id
  where notif_enabled(v_host_id, 'replay_price_prompt') is not false
  on conflict (recipient_id, entity_id) where (type = 'replay_price_prompt')
    do nothing;
end;
$$;

-- ── Fan-out to fans (post-publish) ────────────────────────────────────────────
-- Same recipients + dedupe index as the old notify_replay_ready (0023):
-- followers of the host + paid ticket holders, never the host.

create or replace function fanout_replay_ready(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
begin
  select host_id into v_host_id from events where id = p_event_id;
  if v_host_id is null then
    return;
  end if;

  insert into notifications (recipient_id, actor_id, type, entity_id)
  select uid, v_host_id, 'replay_ready', p_event_id
  from (
    select follower_id as uid from follows where following_id = v_host_id
    union
    select buyer_id as uid from tickets
    where event_id = p_event_id and status = 'paid'
  ) recipients
  where uid <> v_host_id
    and notif_enabled(uid, 'replay_ready') is not false
  on conflict (recipient_id, entity_id) where (type = 'replay_ready') do nothing;
end;
$$;

-- ── publish_replay: host sets the price ───────────────────────────────────────
-- Called by the app (authenticated) from the pricing screen. Idempotent: a
-- second call on a published replay is a no-op (price is locked at publish so
-- buyers always pay what they saw). Requires a ready replay to exist.

create or replace function publish_replay(p_event_id uuid, p_price_cents int)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
  v_published timestamptz;
begin
  if p_price_cents is null or p_price_cents < 0 or p_price_cents > 50000 then
    raise exception 'invalid price';
  end if;

  select host_id, replay_published_at into v_host_id, v_published
    from events where id = p_event_id;

  -- Host-only (never trust the client).
  if v_host_id is null or v_host_id is distinct from auth.uid() then
    raise exception 'not authorized';
  end if;
  if v_published is not null then
    return; -- already published: no-op
  end if;
  if not exists (
    select 1 from replays where event_id = p_event_id and status = 'ready'
  ) then
    raise exception 'no ready replay';
  end if;

  update events
     set replay_price = p_price_cents,
         replay_published_at = now()
   where id = p_event_id;

  perform fanout_replay_ready(p_event_id);
end;
$$;

-- ── auto_publish_replays: 48h fallback ────────────────────────────────────────
-- Hosts who never price the replay: publish at the live price (free → free)
-- once the replay has been ready for 48h. Ready-time proxy = the replay row's
-- created_at (egress rows are created at show start; a show runs hours, not
-- days, so the bound stays comfortably within retention).

create or replace function auto_publish_replays(p_hours int default 48)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  for r in
    select e.id, coalesce(e.price, 0) as live_price
      from events e
     where e.replay_published_at is null
       and exists (
         select 1 from replays rp
          where rp.event_id = e.id
            and rp.status = 'ready'
            and rp.created_at < now() - make_interval(hours => p_hours)
       )
  loop
    update events
       set replay_price = r.live_price,
           replay_published_at = now()
     where id = r.id and replay_published_at is null;

    perform fanout_replay_ready(r.id);
  end loop;
end;
$$;

select cron.schedule(
  'auto-publish-replays',
  '30 * * * *', -- hourly at :30 (offset from the 0024 retention sweeps)
  $$select public.auto_publish_replays()$$
);

-- ── replays RLS: hide unpublished replays from non-crew ───────────────────────
-- Replaces the 0021 policy. Crew (host/operator) always see rows; fans only
-- once published, and then under the same free/ticket gate as before. The
-- signed-URL path in the livekit fn re-checks all of this server-side.

drop policy if exists "replays_select_authorized" on public.replays;
create policy "replays_select_authorized" on public.replays
  for select using (
    exists (
      select 1 from public.events e
      where e.id = replays.event_id
        and (
          e.host_id = auth.uid()
          or exists (
            select 1 from public.event_operators o
            where o.event_id = e.id and o.operator_id = auth.uid()
          )
          or (
            e.replay_published_at is not null
            and (
              coalesce(e.replay_price, 0) = 0
              or exists (
                select 1 from public.tickets t
                where t.event_id = e.id
                  and t.buyer_id = auth.uid()
                  and t.status = 'paid'
              )
            )
          )
        )
    )
  );
