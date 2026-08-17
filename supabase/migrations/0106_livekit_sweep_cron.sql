-- 0106 — schedule livekit-sweep.
--
-- Covers two P1 findings with one job (see the function header for the full
-- reasoning):
--
--   #13  Viewer counts were reconciled by the clients: every viewer ran its own
--        30s timer, each one triggering a server recount and a write to a
--        single hot events row that realtime then fanned back out to all of
--        them. O(N) calls and O(N²) messages for a number that moves by two.
--        The sweep does it once per live event instead.
--
--   #17  auto_end_expired_events (job 3, migration 0084) closes the events row
--        in SQL and never tells LiveKit, so an abandoned room kept publishing
--        and recording until emptyTimeout expired — up to 30 minutes of billed
--        egress and 30 minutes of dead air on the end of a sellable replay.
--        The sweep stops the egress and deletes the room.
--
-- Every minute. pg_cron 1.6 on this project supports sub-minute schedules, but
-- a viewer count is a soft number on a card and a minute of lag is invisible;
-- the abandoned-room half is bounded by the 5-minute auto-end job upstream of
-- it anyway. Cheaper, and it stays legible next to the other jobs.
--
-- Same shared-secret pattern as 0103: the secret is read from Vault at call
-- time so it never appears in cron.job or in this file.
--
-- PREREQUISITE: supabase functions deploy livekit-sweep --no-verify-jwt
-- (cron carries no user JWT; the function gates on x-cron-secret instead).
--
-- cron.schedule() on an existing jobname updates it in place, so re-running
-- this migration preserves the job id and its run history.

do $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'cron_shared_secret';

  if v_secret is null then
    raise exception 'vault secret cron_shared_secret is missing — see migration 0103';
  end if;

  perform cron.schedule(
    'livekit-sweep',
    '* * * * *',
    $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/livekit-sweep',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                           where name = 'cron_shared_secret')
      )
    );
    $job$
  );
end $$;
