-- 0109 — wire live_chat_message into the moderation pipeline (#16 phase 3).
--
-- Requires 0108 (the enum value must be committed before it can be used).
-- Follows the checklist 0067 laid down for adding a report target type:
--   • widen the moderation_audit action-target CHECK,
--   • add a get_report_queue preview branch + joins + is_removed fold,
--   • re-grant execute,
--   • add the matching CONTENT_TABLES entry in the moderate-report Edge
--     Function (done in the same change).
-- The reports dedup/exclusion indexes need nothing — they index the enum
-- column, not specific values.

-- ── moderation_audit: widen the CHECK, and fix what 0071 missed ──────────────
-- ⚠️ This constraint has been WRONG on prod since the Rapids→Currents rename.
-- 0067 widened it to accept 'rapid' and 'rapid_comment'; 0071 renamed the enum
-- values, the tables and the functions but never touched this CHECK. Verified
-- against prod before writing this — the live constraint still lists
-- 'rapid'/'rapid_comment' and rejects 'current'/'current_comment'.
--
-- The failure is silent, which is why it survived: moderate-report's logAudit
-- only console.errors a failed insert. So every moderation action taken on a
-- reported Current since the rename did the moderation and lost the audit
-- trail. Nothing to backfill — those rows were never written.
alter table moderation_audit drop constraint if exists moderation_audit_target_type_check;
alter table moderation_audit add constraint moderation_audit_target_type_check
  check (target_type in (
    'user', 'post', 'event', 'comment', 'ad',
    'current', 'current_comment', 'live_chat_message'
  ));

-- ── get_report_queue: add the live_chat_message preview ──────────────────────
-- Same signature (create or replace is safe). Body adds one preview branch,
-- three joins, and folds live_chat_messages.removed_at into is_removed.
--
-- The event title rides along in the preview: a chat line out of context is
-- close to unreviewable, and "which show was this?" is the first thing a
-- reviewer asks.
create or replace function public.get_report_queue(
  p_limit integer default 20,
  p_before timestamp with time zone default null::timestamp with time zone
)
returns table(target_type report_target_type, target_id uuid, report_count bigint,
              reasons report_reason[], notes text[], statuses report_status[],
              newest_report_at timestamp with time zone, is_removed boolean,
              is_suspended boolean, preview jsonb)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if not is_admin() then
    raise exception 'not authorized';
  end if;

  return query
  with grouped as (
    select
      r.target_type,
      r.target_id,
      count(*)                                       as report_count,
      array_agg(distinct r.reason)                    as reasons,
      array_remove(array_agg(distinct r.note), null)  as notes,
      array_agg(distinct r.status)                    as statuses,
      max(r.created_at)                               as newest_report_at
    from reports r
    where r.status in ('open', 'reviewing')
    group by r.target_type, r.target_id
  )
  select
    g.target_type,
    g.target_id,
    g.report_count,
    g.reasons,
    g.notes,
    g.statuses,
    g.newest_report_at,
    coalesce(p.removed_at, c.removed_at, ev.removed_at, ra.removed_at,
             rc.removed_at, lcm.removed_at) is not null as is_removed,
    (g.target_type = 'user' and prof.suspended_at is not null)      as is_suspended,
    case g.target_type
      when 'post' then jsonb_build_object(
        'exists', p.id is not null,
        'content', p.content,
        'image_url', p.image_url,
        'image_urls', p.image_urls,
        'author_id', p.user_id,
        'author_username', pu.username
      )
      when 'comment' then jsonb_build_object(
        'exists', c.id is not null,
        'body', c.body,
        'post_id', c.post_id,
        'author_id', c.user_id,
        'author_username', cu.username
      )
      when 'event' then jsonb_build_object(
        'exists', ev.id is not null,
        'title', ev.title,
        'cover_image_url', ev.cover_image_url,
        'status', ev.status,
        'host_id', ev.host_id,
        'host_username', eu.username
      )
      when 'ad' then jsonb_build_object(
        'exists', acamp.id is not null,
        'headline', ac.headline,
        'body', ac.body,
        'image_url', ac.image_url,
        'campaign_name', acamp.name,
        'campaign_status', acamp.status,
        'advertiser_name', aacct.name
      )
      when 'current' then jsonb_build_object(
        'exists', ra.id is not null,
        'caption', ra.caption,
        'video_path', ra.video_path,
        'thumb_path', ra.thumb_path,
        'duration_ms', ra.duration_ms,
        'expires_at', ra.expires_at,
        'author_id', ra.user_id,
        'author_username', rau.username
      )
      when 'current_comment' then jsonb_build_object(
        'exists', rc.id is not null,
        'body', rc.body,
        'current_id', rc.current_id,
        'author_id', rc.user_id,
        'author_username', rcu.username
      )
      when 'live_chat_message' then jsonb_build_object(
        'exists', lcm.id is not null,
        'body', lcm.body,
        'event_id', lcm.event_id,
        'event_title', lcev.title,
        'sent_at', lcm.created_at,
        'author_id', lcm.sender_id,
        'author_username', lcmu.username
      )
      when 'user' then jsonb_build_object(
        'exists', prof.id is not null,
        'username', prof.username,
        'display_name', prof.display_name,
        'avatar_url', prof.avatar_url,
        'bio', prof.bio
      )
    end as preview
  from grouped g
  left join posts           p     on g.target_type = 'post'    and p.id = g.target_id
  left join profiles        pu    on pu.id = p.user_id
  left join post_comments   c     on g.target_type = 'comment' and c.id = g.target_id
  left join profiles        cu    on cu.id = c.user_id
  left join events           ev   on g.target_type = 'event'   and ev.id = g.target_id
  left join profiles        eu    on eu.id = ev.host_id
  left join ad_campaigns    acamp on g.target_type = 'ad'      and acamp.id = g.target_id
  left join ad_creatives    ac    on ac.campaign_id = acamp.id
  left join advertiser_accounts aacct on aacct.id = acamp.advertiser_account_id
  left join currents         ra    on g.target_type = 'current' and ra.id = g.target_id
  left join profiles        rau   on rau.id = ra.user_id
  left join current_comments rc    on g.target_type = 'current_comment' and rc.id = g.target_id
  left join profiles        rcu   on rcu.id = rc.user_id
  left join live_chat_messages lcm  on g.target_type = 'live_chat_message' and lcm.id = g.target_id
  left join profiles           lcmu on lcmu.id = lcm.sender_id
  left join events             lcev on lcev.id = lcm.event_id
  left join profiles        prof  on g.target_type = 'user'    and prof.id = g.target_id
  where (p_before is null or g.newest_report_at < p_before)
  order by g.newest_report_at desc
  limit greatest(1, least(p_limit, 100));
end;
$function$;

revoke all on function public.get_report_queue(integer, timestamptz) from public, anon;
grant execute on function public.get_report_queue(integer, timestamptz) to authenticated;
