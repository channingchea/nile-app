-- Phase 20: Push notifications (FCM)
-- Run this entire file in the Supabase SQL editor.
--
-- Design: every in-app notification is already a single INSERT INTO notifications
-- (phases 11/16/17), and phase 18's notif_enabled() gating means no row is
-- inserted for a type the recipient muted. So a single AFTER INSERT trigger on
-- notifications is the universal push hook: it covers every current and future
-- notification type, and inherits per-type mute for free.
--
-- The trigger posts the new row (plus the actor's username/avatar, resolved here
-- to save the Edge Function a round-trip) to the send-push Edge Function via
-- pg_net. The function looks up the recipient's device tokens and sends via FCM.
--
-- Requires the pg_net + supabase_vault extensions and two Vault secrets:
--   push_function_url    — full URL of the send-push Edge Function
--   push_shared_secret   — random string; send-push checks it via x-push-secret
-- Set them once from the SQL editor:
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/send-push', 'push_function_url');
--   select vault.create_secret('<random-string>', 'push_shared_secret');
-- And set the same random string as a function secret:
--   supabase secrets set PUSH_SHARED_SECRET=<random-string>

-- ── Extensions ────────────────────────────────────────────────────────────────

create extension if not exists pg_net with schema extensions;

-- ── device_tokens ─────────────────────────────────────────────────────────────
-- One row per (user, device). token is the FCM registration token. A device may
-- re-register with a new token; we upsert on token and keep last_seen_at fresh.

create table if not exists device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  token        text not null unique,
  platform     text not null check (platform in ('ios', 'android')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists device_tokens_user_idx on device_tokens(user_id);

alter table device_tokens enable row level security;

-- Users manage only their own tokens. The Edge Function reads tokens with the
-- service-role key, which bypasses RLS.
drop policy if exists "device_tokens_select" on device_tokens;
create policy "device_tokens_select"
  on device_tokens for select using (user_id = auth.uid());

drop policy if exists "device_tokens_insert" on device_tokens;
create policy "device_tokens_insert"
  on device_tokens for insert with check (user_id = auth.uid());

drop policy if exists "device_tokens_update" on device_tokens;
create policy "device_tokens_update"
  on device_tokens for update using (user_id = auth.uid());

drop policy if exists "device_tokens_delete" on device_tokens;
create policy "device_tokens_delete"
  on device_tokens for delete using (user_id = auth.uid());

-- ── Trigger: notification insert → send-push ──────────────────────────────────
-- Fires once per notification row. Resolves the actor's display fields, then
-- posts to the Edge Function. We never block the insert on push delivery:
-- net.http_post is async (queued by pg_net), and any failure is swallowed so a
-- transient push problem can't roll back the notification itself.

create or replace function on_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp, extensions, vault
as $$
declare
  v_url      text;
  v_secret   text;
  v_username text;
  v_avatar   text;
begin
  -- Config lives in Supabase Vault (managed Postgres forbids `alter database set`).
  -- push_function_url    — full URL of the send-push Edge Function
  -- push_shared_secret   — random string the function checks via the x-push-secret header
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'push_shared_secret';

  -- If config is missing (e.g. local dev without secrets), no-op cleanly.
  if v_url is null or v_secret is null then
    return new;
  end if;

  select username, avatar_url into v_username, v_avatar
  from profiles where id = new.actor_id;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',   'application/json',
      'x-push-secret',  v_secret
    ),
    body := jsonb_build_object(
      'notification_id', new.id,
      'recipient_id',    new.recipient_id,
      'actor_id',        new.actor_id,
      'actor_username',  coalesce(v_username, 'Someone'),
      'actor_avatar',    v_avatar,
      'type',            new.type,
      'entity_id',       new.entity_id
    )
  );

  return new;
exception
  when others then
    -- Never let a push failure roll back the notification insert.
    return new;
end;
$$;

drop trigger if exists trg_on_notification_push on notifications;
create trigger trg_on_notification_push
  after insert on notifications
  for each row execute function on_notification_push();
