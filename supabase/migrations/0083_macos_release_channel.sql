-- 0083_macos_release_channel.sql
-- macOS ships on its own cadence: a direct download from downloads.joinnile.com
-- rather than a store, cut whenever a tag is pushed. It therefore needs its own
-- version gate — reusing min_build/latest_build would mean an iOS TestFlight
-- build bump instantly telling every Mac user their app is out of date, or
-- worse, hard-blocking them.
--
-- Also widens device_tokens.platform to accept 'macos' so DeviceTokenService
-- can register a Mac. Push itself is still off on macOS (main.dart excludes it
-- from _firebaseSupported) and gets wired up in Phase 6; this just stops the
-- constraint being the thing that blocks it.

alter table public.app_config
  add column if not exists macos_min_build    integer not null default 1,
  add column if not exists macos_latest_build integer not null default 1,
  add column if not exists macos_update_url   text;

comment on column public.app_config.macos_min_build is
  'Builds below this are hard-blocked on macOS. Raise only to kill a broken build.';
comment on column public.app_config.macos_latest_build is
  'Newest published macOS build. Below this shows a dismissible update prompt.';
comment on column public.app_config.macos_update_url is
  'Where the macOS update prompt sends the user. Falls back to update_url.';

update public.app_config
   set macos_latest_build = 4,
       macos_update_url   = 'https://downloads.joinnile.com/mac/Nile.dmg'
 where id = 1;

alter table public.device_tokens
  drop constraint if exists device_tokens_platform_check;
alter table public.device_tokens
  add constraint device_tokens_platform_check
  check (platform = any (array['ios'::text, 'android'::text, 'macos'::text]));
