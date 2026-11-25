-- 0147: Interview mode guests (docs/plans/studio-modes.md, phase 2).
--
-- event_guests        who the host invited, and where they are now:
--                     invited → green_room (joined) ⇄ on_stage; removed.
--                     Written only by the livekit function (service role);
--                     the host and the guest themselves can read it.
-- events.guest_invite_code   the share link (links.joinnile.com/g/<code>);
--                     rotating it kills the old link.
-- event_host_notes    the host's private notes for a show. Its own table
--                     because events rows are readable by everyone.
-- notification_type 'guest_invited'  follows the operator_assigned
--                     preference: both are "someone put you in their show".

-- 'guest_invited' itself is added in 0146 (an enum value can't be used in the
-- transaction that adds it).

alter table public.events
  add column guest_invite_code text unique
  check (guest_invite_code ~ '^[a-z2-9]{10}$');

create table public.event_guests (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  invited_by    uuid references public.profiles(id) on delete set null,
  status        text not null default 'invited'
                check (status in ('invited', 'green_room', 'on_stage', 'removed')),
  title         text check (char_length(title) between 1 and 60),
  joined_at     timestamptz,
  stage_since   timestamptz,
  stage_seconds int not null default 0 check (stage_seconds >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (event_id, user_id)
);

create index event_guests_user on public.event_guests (user_id);

create trigger event_guests_touch
  before update on public.event_guests
  for each row execute function public.studio_graphics_touch();

alter table public.event_guests enable row level security;

create policy event_guests_read on public.event_guests
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.events e where e.id = event_id and e.host_id = auth.uid())
  );

create table public.event_host_notes (
  event_id   uuid primary key references public.events(id) on delete cascade,
  host_id    uuid not null references public.profiles(id) on delete cascade,
  body       text not null default '' check (char_length(body) <= 10000),
  updated_at timestamptz not null default now()
);

create trigger event_host_notes_touch
  before update on public.event_host_notes
  for each row execute function public.studio_graphics_touch();

alter table public.event_host_notes enable row level security;

create policy event_host_notes_own on public.event_host_notes
  for all to authenticated
  using (
    host_id = auth.uid()
    and exists (select 1 from public.events e where e.id = event_id and e.host_id = auth.uid())
  )
  with check (
    host_id = auth.uid()
    and exists (select 1 from public.events e where e.id = event_id and e.host_id = auth.uid())
  );

create or replace function public.notif_enabled(p_uid uuid, p_type notification_type)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select case p_type
      when 'post_like'                  then post_like
      when 'post_comment'               then post_comment
      when 'follow'                     then follow
      when 'event_starting'             then event_starting
      when 'event_live'                 then event_live
      when 'event_ended'                then event_ended
      when 'event_no_show'              then event_ended
      when 'operator_assigned'          then operator_assigned
      when 'guest_invited'              then operator_assigned
      when 'new_message'                then new_message
      when 'message_reaction'           then message_reaction
      when 'replay_ready'               then replay_ready
      when 'tip_received'               then tip_received
      when 'soundcheck_open'            then soundcheck_open
      when 'replay_price_prompt'        then replay_price_prompt
      when 'feedback_resolved'          then feedback_resolved
      when 'sponsorship_offer'          then sponsorship_offer
      when 'sponsorship_offer_expiring' then sponsorship_offer
    end
  from notification_preferences
  where user_id = p_uid;
$function$;

-- The Studio's green room and the guest's own screen follow the list live.
alter publication supabase_realtime add table public.event_guests;
