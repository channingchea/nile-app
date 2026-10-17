-- 0131: RealSync remote switch (Studio master host, phase 7f).
--
-- RealSync holds cameras in step with the show audio by reaching into
-- libwebrtc's jitter buffer (packages/nile_realsync). It self-tests on every
-- launch, but it ships OFF: flip this on only after the hardware rig in
-- docs/plans/studio-master-host.md (phase 7a) passes. Turning it off again
-- takes effect on each app's next launch, no release needed.
alter table public.app_config
  add column if not exists realsync_enabled boolean not null default false;
