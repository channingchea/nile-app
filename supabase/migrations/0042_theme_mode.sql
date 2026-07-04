-- Per-user theme preference, mirrored from the app for cross-device sync.
-- Local storage is the source of truth for immediate paint; this value is
-- adopted only on devices with no local choice yet (fresh install).
alter table public.profiles
  add column if not exists theme_mode text not null default 'dark'
  check (theme_mode in ('system', 'light', 'dark'));
