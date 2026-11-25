-- 0145: Studio modes (docs/plans/studio-modes.md, phase 1).
--
-- events.studio_mode — how the Studio runs the show: 'multicam' (the layout
-- every show had before), 'interview' (green room + stage) or 'premiere'
-- (uploaded film). Set at create/edit and from the Studio's mode switch
-- (livekit `set-mode`, which also mirrors it into room metadata `mode`).
-- Locked once the show is live — the trigger holds that rule for direct
-- client updates as well as the edge function.

alter table public.events
  add column studio_mode text not null default 'multicam'
  check (studio_mode in ('multicam', 'interview', 'premiere'));

create or replace function public.events_lock_studio_mode()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.studio_mode is distinct from old.studio_mode and old.status = 'live' then
    raise exception 'The studio mode can''t change while the show is live'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger events_lock_studio_mode
  before update of studio_mode on public.events
  for each row execute function public.events_lock_studio_mode();
