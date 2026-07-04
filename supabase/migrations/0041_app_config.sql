-- Phase 4 — force-update / kill switch.
-- A single-row table the client reads at startup to decide whether the running
-- build is still supported. `min_build` is the hard floor (below it the app
-- blocks and demands an update); `latest_build` drives a soft "update available"
-- nudge. Writable only by the service role / admins (no client write policy).

create table if not exists public.app_config (
  id           smallint primary key default 1,
  min_build    integer     not null default 1,
  latest_build integer     not null default 1,
  update_url   text,
  message      text,
  updated_at   timestamptz not null default now(),
  constraint app_config_singleton check (id = 1)
);

alter table public.app_config enable row level security;

-- Everyone (incl. signed-out clients) may read the single config row.
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config
  for select using (true);

-- Seed the singleton so the read always returns a row. Bump min_build/
-- latest_build here (or via the dashboard) when shipping a forced update.
insert into public.app_config (id, min_build, latest_build, message)
values (1, 1, 1, null)
on conflict (id) do nothing;
