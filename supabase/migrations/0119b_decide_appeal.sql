-- 0119b_decide_appeal.sql
-- Companion to 0119. The admin side of an appeal.
--
-- `appeals` is client-unwritable by design (0119), so the portal needs one
-- narrow, admin-gated write. An RPC rather than an Edge Function because the
-- whole operation is a single UPDATE with an authorization check — the same
-- shape as the other admin RPCs.

create or replace function public.decide_appeal(
  p_id uuid,
  p_status text,
  p_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  if p_status not in ('upheld', 'overturned') then
    raise exception 'status must be upheld or overturned' using errcode = '22023';
  end if;

  -- Only an open appeal can be decided: two admins opening the queue at once
  -- must not overwrite each other's decision.
  update public.appeals
     set status = p_status,
         decided_at = now(),
         decided_by = auth.uid(),
         decision_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id
     and status = 'open';

  if not found then
    raise exception 'Appeal not found, or already decided' using errcode = '42P10';
  end if;
end;
$$;

-- `public` must be named: CREATE FUNCTION grants EXECUTE to PUBLIC, so
-- revoking from anon and authenticated alone would be a no-op.
revoke execute on function public.decide_appeal(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.decide_appeal(uuid, text, text) to authenticated;
