-- 0151: Premiere films (docs/plans/studio-modes.md, phase 6).
--
-- One row per Premiere event: the film and its optional trailer, both stored
-- in Cloudflare Stream with signed URLs required, plus the filmmaker's
-- choices (rating, content warning, replay window, chat during the film) and
-- the "I own the rights" confirmation.
--
-- Written only by the premiere / premiere-webhook functions (service role).
-- The host reads their own row (and follows it live while a film processes).
-- Nobody else reads it: viewers get what they need through the functions.
--
-- The premiere-webhook function also runs the hourly sweep (job below): it
-- sets delete_after once the show has ended, sends a reminder two days before,
-- and deletes the film from Stream when the window has passed.

create table public.event_films (
  event_id            uuid primary key references public.events(id) on delete cascade,
  host_id             uuid not null references public.profiles(id) on delete cascade,
  film_uid            text,
  film_status         text not null default 'none'
                      check (film_status in ('none', 'uploading', 'processing', 'ready', 'error')),
  film_error          text,
  film_name           text check (char_length(film_name) <= 200),
  film_bytes          bigint check (film_bytes >= 0),
  film_duration_s     numeric check (film_duration_s >= 0),
  trailer_uid         text,
  trailer_status      text not null default 'none'
                      check (trailer_status in ('none', 'uploading', 'processing', 'ready', 'error')),
  trailer_error       text,
  trailer_duration_s  numeric check (trailer_duration_s >= 0),
  playback_host       text,
  captions            jsonb not null default '[]'::jsonb,
  poster_url          text check (char_length(poster_url) <= 1000),
  rating              text check (rating in ('G', 'PG', 'PG-13', 'R', 'NC-17', 'NR', '18+')),
  content_warning     text check (char_length(content_warning) <= 200),
  replay_policy       text not null default 'none'
                      check (replay_policy in ('none', '24h', '48h', '7d', 'forever')),
  chat_policy         text not null default 'open'
                      check (chat_policy in ('open', 'reactions', 'slow')),
  rights_confirmed_at timestamptz,
  delete_after        timestamptz,
  reminder_sent_at    timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index event_films_host on public.event_films (host_id);
create index event_films_film_uid on public.event_films (film_uid) where film_uid is not null;
create index event_films_trailer_uid on public.event_films (trailer_uid) where trailer_uid is not null;

create trigger event_films_touch
  before update on public.event_films
  for each row execute function public.studio_graphics_touch();

alter table public.event_films enable row level security;
revoke all on public.event_films from anon, authenticated;
grant select on public.event_films to authenticated;

create policy event_films_host_read on public.event_films
  for select to authenticated
  using (
    host_id = auth.uid()
    and exists (select 1 from public.events e where e.id = event_id and e.host_id = auth.uid())
  );

alter publication supabase_realtime add table public.event_films;

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
      when 'film_expiring'              then replay_ready
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

-- Hourly sweep, same shared-secret pattern as 0106 (secret read from Vault at
-- call time, never stored in cron.job).
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'cron_shared_secret') then
    raise exception 'vault secret cron_shared_secret is missing — see migration 0103';
  end if;
  perform cron.schedule(
    'premiere-sweep',
    '17 * * * *',
    $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/premiere-webhook',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                           where name = 'cron_shared_secret')
      ),
      body    := '{"sweep":true}'::jsonb
    );
    $job$
  );
end $$;
