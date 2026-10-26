-- 0141: polls (docs/plans/studio-poll.md, phase 1) — a vote may hold several
-- picks, and votes carry the poll's round so a reset starts clean.
--
-- `choice` stays (the first pick) so the livekit function deployed before
-- this one keeps working until it is replaced; the old 4-argument
-- element_respond and element_tally stay for the same reason.

alter table public.element_responses
  add column if not exists picks text[],
  add column if not exists round int not null default 0;

update public.element_responses set picks = array[choice] where picks is null;

alter table public.element_responses
  alter column picks set not null,
  add constraint element_responses_picks_size check (cardinality(picks) between 1 and 6);

-- A vote: [p_picks] replace whatever this viewer held. 'slow' when they
-- changed it under a second ago in the same round, else 'ok'.
create or replace function public.element_respond(
  p_event uuid, p_element text, p_user uuid, p_picks text[], p_round int
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v record;
begin
  select updated_at, round into v
    from element_responses
   where event_id = p_event and element_id = p_element and user_id = p_user
   for update;
  if found and v.round = p_round and v.updated_at > now() - interval '1 second' then
    return 'slow';
  end if;
  insert into element_responses (event_id, element_id, user_id, choice, picks, round, updated_at)
  values (p_event, p_element, p_user, p_picks[1], p_picks, p_round, now())
  on conflict (event_id, element_id, user_id)
  do update set choice = excluded.choice, picks = excluded.picks,
                round = excluded.round, updated_at = excluded.updated_at;
  return 'ok';
end
$$;

-- This round's totals: { counts: pick → count, voters: people who voted }.
-- With several picks a vote counts once per pick, so voters ≤ the sum.
create or replace function public.element_tally(p_event uuid, p_element text, p_round int)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'counts', coalesce((
      select jsonb_object_agg(pick, n)
        from (
          select pick, count(*)::int as n
            from element_responses r, unnest(r.picks) as pick
           where r.event_id = p_event and r.element_id = p_element and r.round = p_round
           group by pick
        ) t
    ), '{}'::jsonb),
    'voters', (
      select count(*)::int
        from element_responses
       where event_id = p_event and element_id = p_element and round = p_round
    )
  )
$$;

revoke all on function public.element_respond(uuid, text, uuid, text[], int) from public, anon, authenticated;
revoke all on function public.element_tally(uuid, text, int) from public, anon, authenticated;
grant execute on function public.element_respond(uuid, text, uuid, text[], int) to service_role;
grant execute on function public.element_tally(uuid, text, int) to service_role;
