-- 0156: cost controls, part 2 — free-show limits
-- (docs/plans/cost-controls-and-60-payout.md, phase 3).
--
-- A free show runs at most free_max_stream_minutes (2 hours). The trigger
-- refuses a longer one (free_duration_exceeds_max) and the auto-end cron stops
-- a live one at the limit. The update trigger (0153) only fires when price,
-- cameras, schedule or mode change, so a free show already scheduled past
-- 2 hours is left alone until it is edited — but the cron still ends it at
-- 2 hours once live.

alter table public.app_config
  add column if not exists free_max_stream_minutes int not null default 120
    check (free_max_stream_minutes > 0);

create or replace function public.enforce_event_pricing_limits()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_max_minutes  int;
  v_free_minutes int;
  v_minutes      int;
  v_floor        int;
begin
  select max_stream_minutes, free_max_stream_minutes
    into v_max_minutes, v_free_minutes
    from public.app_config where id = 1;
  v_max_minutes  := coalesce(v_max_minutes, 480);
  v_free_minutes := coalesce(v_free_minutes, 120);

  if new.scheduled_at is not null and new.end_at is not null then
    v_minutes := ceil(
      extract(epoch from (new.end_at - new.scheduled_at)) / 60.0
    )::int;
    if v_minutes > v_max_minutes then
      raise exception 'duration_exceeds_max'
        using hint = 'Streams are capped at '
                     || (v_max_minutes / 60) || ' hours.';
    end if;
    if coalesce(new.price, 0) = 0 and v_minutes > v_free_minutes then
      raise exception 'free_duration_exceeds_max'
        using hint = 'Free shows are capped at '
                     || (v_free_minutes / 60) || ' hours.';
    end if;
  end if;

  if coalesce(new.camera_count, 1) > 1 and coalesce(new.price, 0) = 0 then
    raise exception 'multicam_requires_ticket'
      using hint = 'Multi-camera streams need a ticket price.';
  end if;

  if coalesce(new.price, 0) > 0 then
    v_floor := public.compute_min_ticket_cents(
      coalesce(v_minutes, 60),
      coalesce(new.camera_count, 1),
      coalesce(new.studio_mode, 'multicam')
    );
    if new.price < v_floor then
      raise exception 'price_below_minimum'
        using hint = 'Minimum for this event is $'
                     || to_char(v_floor / 100.0, 'FM999990.00') || '.';
    end if;
  end if;

  return new;
end;
$$;

-- Same as before, plus: a live free show stops at free_max_stream_minutes.
create or replace function public.auto_end_expired_events(p_grace_minutes integer default 2)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count        integer;
  v_max_minutes  integer;
  v_free_minutes integer;
begin
  select max_stream_minutes, free_max_stream_minutes
    into v_max_minutes, v_free_minutes
    from public.app_config where id = 1;
  v_max_minutes  := coalesce(v_max_minutes, 480);
  v_free_minutes := coalesce(v_free_minutes, 120);

  with expired as (
    update public.events e
       set status = 'ended',
           -- A no-show never ran, so stamp it with the close of its scheduled
           -- window rather than now() — otherwise a June event backfilled
           -- today would read as having "just ended".
           ended_at = case
             when e.status = 'live' then now()
             else least(
                    now(),
                    coalesce(
                      e.end_at,
                      e.scheduled_at + make_interval(mins => v_max_minutes)
                    )
                  )
           end
     where (
       -- Went live, but is past its planned duration or the hard stream cap
       -- (the shorter free-show cap when it sells no ticket).
       e.status = 'live'
       and (
         (e.end_at is not null
          and coalesce(
                e.started_at + (e.end_at - e.scheduled_at),
                e.end_at
              ) < now() - make_interval(mins => p_grace_minutes))
         or (e.started_at is not null
             and e.started_at < now() - make_interval(
                   mins => case when coalesce(e.price, 0) = 0
                                then least(v_free_minutes, v_max_minutes)
                                else v_max_minutes end
                           + p_grace_minutes))
       )
     ) or (
       -- Never went live: host no-show, or an abandoned Sound Check. Events
       -- with neither end_at nor scheduled_at are left alone (coalesce is
       -- null, so the comparison is null and the row is not matched).
       e.status in ('scheduled', 'soundcheck')
       and coalesce(
             e.end_at,
             e.scheduled_at + make_interval(mins => v_max_minutes)
           ) < now() - make_interval(
                 mins => case when e.status = 'soundcheck'
                              then greatest(p_grace_minutes, 30)
                              else p_grace_minutes end
               )
     )
    returning e.id
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;
