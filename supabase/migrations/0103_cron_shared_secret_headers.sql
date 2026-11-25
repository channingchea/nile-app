-- 0103_cron_shared_secret_headers.sql
-- P0.5 (part 1 of 2) — send a shared secret on the two cron -> Edge Function
-- calls, so those endpoints can stop accepting anonymous internet traffic.
--
-- tally-ad-spend and notify-event-starting are both deployed --no-verify-jwt
-- and neither read the Authorization header, so anyone who knows the URL (it
-- is sitting in 0085's committed migration body) could drive them. Against
-- tally-ad-spend that means live Stripe refund/cancel calls, the offer-expiry
-- sweep, the abandoned-checkout delete, and unlimited Klaviyo email + FCM push.
--
-- 0085 correctly stripped the plaintext service-role JWT out of cron.job but
-- nothing replaced it, leaving the endpoints with no auth at all.
--
-- The secret is read from Vault at call time rather than inlined, so it never
-- appears in cron.job, in this migration, or anywhere in the repo. Its twin is
-- the CRON_SHARED_SECRET Edge Function secret.
--
-- PREREQUISITE (run once, outside version control, before this migration):
--   supabase secrets set CRON_SHARED_SECRET=<value>
--   select vault.create_secret('<same value>', 'cron_shared_secret',
--     'Shared secret proving cron -> Edge Function calls originate from us');
--
-- ORDER MATTERS: this ships BEFORE the functions start enforcing the header.
-- Until they do, the extra header is simply ignored — so there is no window in
-- which cron is locked out of its own endpoints. Part 2 is the `expected`
-- check at the top of each function's serve().
--
-- cron.schedule() on an existing jobname updates it in place, so job ids and
-- run history are preserved.

do $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'cron_shared_secret';

  if v_secret is null then
    raise exception 'vault secret cron_shared_secret is missing — create it before running this migration';
  end if;

  perform cron.schedule(
    'notify-event-starting',
    '*/5 * * * *',
    $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/notify-event-starting',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                           where name = 'cron_shared_secret')
      )
    );
    $job$
  );

  perform cron.schedule(
    'tally-ad-spend',
    '10 3 * * *',
    $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/tally-ad-spend',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                           where name = 'cron_shared_secret')
      )
    );
    $job$
  );

  perform cron.schedule(
    'tally-ad-spend-lobby-aging',
    '5 */2 * * *',
    $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/tally-ad-spend',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                           where name = 'cron_shared_secret')
      ),
      body    := jsonb_build_object('mode', 'lobby-aging')
    );
    $job$
  );
end $$;

-- Verified after applying: anonymous POST to either endpoint returns 401, and a
-- net.http_post carrying the Vault-sourced header returns 200
-- ({"ok":true,"events_processed":0,"notified":0}).
