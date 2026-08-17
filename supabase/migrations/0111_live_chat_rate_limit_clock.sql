-- 0111 — the chat rate limiter measures real time, not transaction time.
--
-- 0107 wrote the token bucket with now(), which in Postgres is
-- transaction_timestamp() — fixed for the whole transaction. Every call from
-- the edge function is its own transaction, so production behaviour was
-- correct and this changes nothing there.
--
-- It is still worth fixing for two reasons.
--
-- Correctness at the edge: if these calls ever share a transaction — batched,
-- wrapped in an RPC, retried inside one — now() reports zero elapsed time and
-- the bucket never refills, so the limiter silently becomes "one message per
-- transaction" instead of five per ten seconds. It fails closed rather than
-- open, but it fails for a reason that has nothing to do with the sender.
--
-- Testability, which is the real motivation: with now(), the refill path cannot
-- be exercised by waiting. The only way to prove a bucket refills is to
-- backdate updated_at by hand, which tests the backdating as much as the code.
-- With clock_timestamp() a probe can pg_sleep and watch it actually happen —
-- see the verification note in docs/plans/live-chat-moderation.md.
--
-- clock_timestamp() is the wall clock at the moment of the call, which is what
-- "how long since your last message" means.

create or replace function public.consume_live_chat_token(
  p_event_id          uuid,
  p_user_id           uuid,
  p_capacity          double precision default 10,
  p_refill_per_second double precision default 0.5
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tokens double precision;
begin
  insert into public.live_chat_rate_limit (event_id, user_id, tokens, updated_at)
  values (p_event_id, p_user_id, p_capacity - 1, clock_timestamp())
  on conflict (event_id, user_id) do update
     set tokens = least(
           p_capacity,
           live_chat_rate_limit.tokens
             + extract(epoch from (clock_timestamp() - live_chat_rate_limit.updated_at))
               * p_refill_per_second
         ) - 1,
         updated_at = clock_timestamp()
  returning tokens into v_tokens;

  -- Empty bucket. Refuse, and hand the token back so a refused message does
  -- not dig the hole deeper — otherwise someone hammering send extends their
  -- own timeout every time they try.
  if v_tokens < 0 then
    update public.live_chat_rate_limit
       set tokens = 0
     where event_id = p_event_id and user_id = p_user_id;
    return false;
  end if;

  return true;
end;
$function$;

revoke all on function public.consume_live_chat_token(uuid, uuid, double precision, double precision)
  from public, anon, authenticated;
grant execute on function public.consume_live_chat_token(uuid, uuid, double precision, double precision)
  to service_role;
