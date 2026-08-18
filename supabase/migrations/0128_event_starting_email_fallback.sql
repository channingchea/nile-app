-- 0128 — P4 #38, last part: no email fallback for "your event starts in 15
-- minutes".
--
-- Push is the only channel that reminder has ever had. Someone who bought a
-- ticket and then denied the notification permission, or signed in on a device
-- that never registered a token, gets nothing at all — they simply miss a show
-- they paid for. That is the one notification on the platform where being
-- unreachable costs the user money.
--
-- This returns exactly the people push cannot reach: paid ticket holders, who
-- have not turned the reminder off, and who have no device token at all.
-- Deliberately NOT "everyone with a ticket" — an email that duplicates a push
-- they already got is how people learn to ignore both.
--
-- Followers are excluded even though fanout_event_starting notifies them: they
-- didn't pay, and unsolicited mail about an event you merely followed the host
-- of is a different product decision.

create or replace function public.unreachable_ticket_holders(p_event_id uuid)
returns table (
  user_id      uuid,
  email        text,
  display_name text,
  event_title  text,
  scheduled_at timestamptz
)
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    t.buyer_id,
    u.email::text,
    coalesce(pr.display_name, pr.username, 'there'),
    e.title,
    e.scheduled_at
  from tickets t
  join events    e  on e.id = t.event_id
  join auth.users u on u.id = t.buyer_id
  left join profiles pr on pr.id = t.buyer_id
  where t.event_id = p_event_id
    and t.status = 'paid'
    and t.buyer_id is not null            -- anonymized buyers (0118) have nobody to mail
    and u.email is not null
    and notif_enabled(t.buyer_id, 'event_starting') is not false
    and not exists (
      select 1 from device_tokens d where d.user_id = t.buyer_id
    );
$$;

-- notify-event-starting is the only caller, on the service role.
revoke execute on function public.unreachable_ticket_holders(uuid)
  from public, anon, authenticated;
