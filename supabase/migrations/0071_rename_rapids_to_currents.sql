-- 0071_rename_rapids_to_currents.sql
-- Renames the "Rapids" feature to "Currents" (one item = a Current).
-- Covers tables, columns, constraints, indexes, triggers, RLS policies,
-- functions, the report_target_type enum, app_config, the storage bucket and
-- the purge cron job.
--
-- Safe to run: authored while the feature carried 0 rows and 0 storage objects.
-- Storage objects are moved (not dropped) so it stays correct if rows appear.

begin;

-- ── 1. Tables ────────────────────────────────────────────────────────────────
alter table public.rapids          rename to currents;
alter table public.rapid_likes     rename to current_likes;
alter table public.rapid_comments  rename to current_comments;
alter table public.rapid_views     rename to current_views;
alter table public.rapid_images    rename to current_images;

-- ── 2. Columns ───────────────────────────────────────────────────────────────
alter table public.current_likes    rename column rapid_id to current_id;
alter table public.current_comments rename column rapid_id to current_id;
alter table public.current_views    rename column rapid_id to current_id;
alter table public.current_images   rename column rapid_id to current_id;
alter table public.app_config       rename column rapids_ad_frequency to currents_ad_frequency;

-- ── 3. Constraints ───────────────────────────────────────────────────────────
-- FK names matter: the app uses them as PostgREST embed hints
-- (profiles!currents_user_id_fkey).
alter table public.currents rename constraint rapids_caption_check     to currents_caption_check;
alter table public.currents rename constraint rapids_duration_ms_check to currents_duration_ms_check;
alter table public.currents rename constraint rapids_media_shape       to currents_media_shape;
alter table public.currents rename constraint rapids_media_type_check  to currents_media_type_check;
alter table public.currents rename constraint rapids_pkey              to currents_pkey;
alter table public.currents rename constraint rapids_removed_by_fkey   to currents_removed_by_fkey;
alter table public.currents rename constraint rapids_user_id_fkey      to currents_user_id_fkey;

alter table public.current_comments rename constraint rapid_comments_body_check       to current_comments_body_check;
alter table public.current_comments rename constraint rapid_comments_pkey             to current_comments_pkey;
alter table public.current_comments rename constraint rapid_comments_rapid_id_fkey    to current_comments_current_id_fkey;
alter table public.current_comments rename constraint rapid_comments_removed_by_fkey  to current_comments_removed_by_fkey;
alter table public.current_comments rename constraint rapid_comments_user_id_fkey     to current_comments_user_id_fkey;

alter table public.current_images rename constraint rapid_images_duration_ms_check      to current_images_duration_ms_check;
alter table public.current_images rename constraint rapid_images_pkey                   to current_images_pkey;
alter table public.current_images rename constraint rapid_images_rapid_id_fkey          to current_images_current_id_fkey;
alter table public.current_images rename constraint rapid_images_rapid_id_position_key  to current_images_current_id_position_key;

alter table public.current_likes rename constraint rapid_likes_pkey          to current_likes_pkey;
alter table public.current_likes rename constraint rapid_likes_rapid_id_fkey to current_likes_current_id_fkey;
alter table public.current_likes rename constraint rapid_likes_user_id_fkey  to current_likes_user_id_fkey;

alter table public.current_views rename constraint rapid_views_pkey           to current_views_pkey;
alter table public.current_views rename constraint rapid_views_rapid_id_fkey  to current_views_current_id_fkey;
alter table public.current_views rename constraint rapid_views_viewer_id_fkey to current_views_viewer_id_fkey;

alter table public.app_config rename constraint app_config_rapids_ad_frequency_check to app_config_currents_ad_frequency_check;

-- ── 4. Plain indexes (constraint-backed ones were renamed above) ─────────────
alter index public.rapids_live_idx                 rename to currents_live_idx;
alter index public.rapids_user_created_idx         rename to currents_user_created_idx;
alter index public.rapid_comments_rapid_created_idx rename to current_comments_current_created_idx;
alter index public.rapid_images_rapid_idx          rename to current_images_current_idx;
alter index public.rapid_likes_rapid_idx           rename to current_likes_current_idx;
alter index public.rapid_views_rapid_idx           rename to current_views_current_idx;

-- ── 5. Triggers ──────────────────────────────────────────────────────────────
alter trigger rapid_comments_count_ins on public.current_comments rename to current_comments_count_ins;
alter trigger rapid_comments_count_del on public.current_comments rename to current_comments_count_del;
alter trigger rapid_likes_count_ins    on public.current_likes    rename to current_likes_count_ins;
alter trigger rapid_likes_count_del    on public.current_likes    rename to current_likes_count_del;
alter trigger rapid_views_count_ins    on public.current_views    rename to current_views_count_ins;

-- ── 6. RLS policies ──────────────────────────────────────────────────────────
alter policy rapids_select_visible on public.currents rename to currents_select_visible;
alter policy rapids_insert_own     on public.currents rename to currents_insert_own;
alter policy rapids_delete_own     on public.currents rename to currents_delete_own;

alter policy rapid_likes_select_all on public.current_likes rename to current_likes_select_all;
alter policy rapid_likes_insert_own on public.current_likes rename to current_likes_insert_own;
alter policy rapid_likes_delete_own on public.current_likes rename to current_likes_delete_own;

alter policy rapid_comments_select_visible on public.current_comments rename to current_comments_select_visible;
alter policy rapid_comments_insert_own     on public.current_comments rename to current_comments_insert_own;
alter policy rapid_comments_delete_own     on public.current_comments rename to current_comments_delete_own;

alter policy rapid_views_select_own on public.current_views rename to current_views_select_own;
alter policy rapid_views_insert_own on public.current_views rename to current_views_insert_own;

-- current_images policies reference the parent by column name, so recreate them.
drop policy if exists rapid_images_select_visible on public.current_images;
drop policy if exists rapid_images_insert_own     on public.current_images;
drop policy if exists rapid_images_delete_own     on public.current_images;

create policy current_images_select_visible on public.current_images
  for select using (
    exists (select 1 from public.currents c where c.id = current_images.current_id)
  );

create policy current_images_insert_own on public.current_images
  for insert with check (
    exists (select 1 from public.currents c
             where c.id = current_images.current_id and c.user_id = auth.uid())
  );

create policy current_images_delete_own on public.current_images
  for delete using (
    exists (select 1 from public.currents c
             where c.id = current_images.current_id and c.user_id = auth.uid())
  );

-- ── 7. Report target enum ────────────────────────────────────────────────────
alter type public.report_target_type rename value 'rapid'         to 'current';
alter type public.report_target_type rename value 'rapid_comment' to 'current_comment';

-- ── 8. Storage bucket ────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public)
values ('currents', 'currents', true)
on conflict (id) do nothing;

update storage.objects set bucket_id = 'currents' where bucket_id = 'rapids';

-- storage.protect_delete() blocks direct deletes from storage tables; unlock it
-- for this transaction only, exactly as purge_expired_currents does.
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.buckets where id = 'rapids';

drop policy if exists rapids_storage_owner_write  on storage.objects;
drop policy if exists rapids_storage_owner_delete on storage.objects;

create policy currents_storage_owner_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'currents'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

create policy currents_storage_owner_delete on storage.objects
  for delete
  using (
    bucket_id = 'currents'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

-- ── 9. Counter trigger functions (rename + rewrite bodies) ───────────────────
alter function public.bump_rapid_comment_count() rename to bump_current_comment_count;
alter function public.bump_rapid_like_count()    rename to bump_current_like_count;
alter function public.bump_rapid_view_count()    rename to bump_current_view_count;

create or replace function public.bump_current_comment_count()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
begin
  if (tg_op = 'INSERT') then
    update currents set comment_count = comment_count + 1 where id = new.current_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update currents set comment_count = greatest(0, comment_count - 1) where id = old.current_id;
    return old;
  end if;
  return null;
end;
$function$;

create or replace function public.bump_current_like_count()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
begin
  if (tg_op = 'INSERT') then
    update currents set like_count = like_count + 1 where id = new.current_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update currents set like_count = greatest(0, like_count - 1) where id = old.current_id;
    return old;
  end if;
  return null;
end;
$function$;

create or replace function public.bump_current_view_count()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
begin
  update currents set view_count = view_count + 1 where id = new.current_id;
  return new;
end;
$function$;

-- ── 10. Rail / feed / ads / purge RPCs ───────────────────────────────────────
-- Dropped + recreated because their OUT column names change.
drop function if exists public.get_rapids_rail(integer);
drop function if exists public.get_rapids_feed(integer);
drop function if exists public.get_rapids_ads(integer, integer);
drop function if exists public.purge_expired_rapids(integer);

create or replace function public.get_currents_rail(page_limit integer default 30)
returns table(user_id uuid, username text, avatar_url text, is_official boolean,
              current_count bigint, latest_current_at timestamp with time zone,
              has_unwatched boolean, is_followed boolean)
language sql
stable
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
  select
    r.user_id,
    p.username,
    p.avatar_url,
    p.is_official,
    count(*)                           as current_count,
    max(r.created_at)                  as latest_current_at,
    bool_or(v.viewer_id is null)       as has_unwatched,
    bool_or(f.follower_id is not null) as is_followed
  from currents r
  join profiles p on p.id = r.user_id
  left join current_views v on v.current_id = r.id and v.viewer_id = auth.uid()
  left join follows f on f.follower_id = auth.uid() and f.following_id = r.user_id
  where r.expires_at > now()
    and r.removed_at is null
    and r.user_id <> auth.uid()
  group by r.user_id, p.username, p.avatar_url, p.is_official
  order by
    bool_or(f.follower_id is not null) desc,
    bool_or(v.viewer_id is null) desc,
    max(r.created_at) desc
  limit page_limit;
$function$;

create or replace function public.get_currents_feed(page_limit integer default 200)
returns table(id uuid, user_id uuid, username text, avatar_url text,
              is_official boolean, media_type text, video_path text,
              thumb_path text, images jsonb, caption text, duration_ms integer,
              like_count integer, comment_count integer, view_count integer,
              created_at timestamp with time zone, liked_by_me boolean,
              watched_by_me boolean, is_followed boolean)
language sql
stable
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
  select
    r.id, r.user_id, p.username, p.avatar_url, p.is_official,
    r.media_type, r.video_path, r.thumb_path,
    coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'path', ri.image_path,
                 'duration_ms', ri.duration_ms,
                 'position', ri.position)
               order by ri.position)
      from current_images ri where ri.current_id = r.id
    ), '[]'::jsonb) as images,
    r.caption, r.duration_ms,
    r.like_count, r.comment_count, r.view_count, r.created_at,
    (l.user_id   is not null) as liked_by_me,
    (v.viewer_id is not null) as watched_by_me,
    (f.follower_id is not null) as is_followed
  from currents r
  join profiles p on p.id = r.user_id
  left join current_likes l on l.current_id = r.id and l.user_id   = auth.uid()
  left join current_views v on v.current_id = r.id and v.viewer_id = auth.uid()
  left join follows f on f.follower_id = auth.uid() and f.following_id = r.user_id
  where r.expires_at > now()
    and r.removed_at is null
    and r.user_id <> auth.uid()
  order by
    (f.follower_id is not null) desc,
    bool_or(v.viewer_id is null) over (partition by r.user_id) desc,
    max(r.created_at) over (partition by r.user_id) desc,
    r.user_id,
    r.created_at asc
  limit page_limit;
$function$;

create or replace function public.get_currents_ads(page_limit integer default 5, freq_cap integer default 3)
returns table(campaign_id uuid, video_path text, thumb_path text, headline text,
              body text, click_url text, advertiser_name text, duration_ms integer)
language sql
stable security definer
set search_path to 'public'
as $function$
  select
    c.id, cr.video_path, cr.thumb_path, cr.headline, cr.body, cr.click_url,
    a.name, cr.duration_ms
  from ad_campaigns c
  join ad_creatives        cr on cr.campaign_id = c.id and cr.kind = 'video'
  left join ad_targeting       t  on t.campaign_id  = c.id
  left join advertiser_accounts a  on a.id          = c.advertiser_account_id
  where c.status = 'active'
    and now() between c.starts_at and c.ends_at
    and c.spent_cents < c.budget_cents
    -- Topic targeting: if topic_ids is set, require overlap with the viewer's
    -- interests; untargeted (empty/null) campaigns serve broadly.
    and (
      t.topic_ids is null
      or cardinality(t.topic_ids) = 0
      or auth.uid() is null
      or exists (
        select 1 from user_topics ut
        where ut.user_id = auth.uid()
          and ut.topic_id = any (t.topic_ids)
      )
    )
    -- frequency cap: skip campaigns this viewer has seen >= freq_cap times today
    and (
      auth.uid() is null
      or (
        select count(*) from ad_events ae
        where ae.campaign_id = c.id
          and ae.viewer_id = auth.uid()
          and ae.kind = 'impression'
          and ae.created_at >= date_trunc('day', now())
      ) < freq_cap
    )
    -- viewer said "not interested" — permanent exclusion for that viewer
    and (
      auth.uid() is null
      or not exists (
        select 1 from ad_events ni
        where ni.campaign_id = c.id
          and ni.viewer_id = auth.uid()
          and ni.kind = 'not_interested'
      )
    )
    -- viewer reported this ad — permanent exclusion for that viewer
    and (
      auth.uid() is null
      or not exists (
        select 1 from reports r
        where r.reporter_id = auth.uid()
          and r.target_type = 'ad'
          and r.target_id = c.id
      )
    )
    -- block exclusion via the account's linked profile, if any
    and not exists (
      select 1 from blocks b
      where a.profile_id is not null and (
        (b.blocker_id = auth.uid() and b.blocked_id = a.profile_id)
        or (b.blocked_id = auth.uid() and b.blocker_id = a.profile_id)
      )
    )
  order by c.starts_at desc
  limit page_limit;
$function$;

create or replace function public.purge_expired_currents(p_grace_days integer default 30)
returns integer
language plpgsql
security definer
set search_path to 'public', 'storage', 'pg_temp'
as $function$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  delete from storage.objects o
   using public.currents r
   where o.bucket_id = 'currents'
     and o.name in (r.video_path, r.thumb_path)
     and r.expires_at < now() - make_interval(days => p_grace_days);

  delete from storage.objects o
   using public.current_images ri
   join public.currents r on r.id = ri.current_id
   where o.bucket_id = 'currents'
     and o.name = ri.image_path
     and r.expires_at < now() - make_interval(days => p_grace_days);

  with purged as (
    delete from public.currents
     where expires_at < now() - make_interval(days => p_grace_days)
    returning id
  )
  select count(*) into v_count from purged;
  return v_count;
end;
$function$;

-- Restore the grants the dropped functions carried.
grant execute on function public.get_currents_rail(integer) to anon, authenticated, service_role;
grant execute on function public.get_currents_feed(integer) to anon, authenticated, service_role;
grant execute on function public.get_currents_ads(integer, integer) to anon, authenticated, service_role;
revoke all on function public.purge_expired_currents(integer) from public, anon, authenticated;
grant execute on function public.purge_expired_currents(integer) to service_role;

-- ── 11. Functions that merely reference the renamed objects ──────────────────
-- Recreated so their stored bodies keep compiling after the rename.

create or replace function public.get_report_queue(p_limit integer default 20, p_before timestamp with time zone default null::timestamp with time zone)
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
    coalesce(p.removed_at, c.removed_at, ev.removed_at, ra.removed_at, rc.removed_at) is not null as is_removed,
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
  left join profiles        prof  on g.target_type = 'user'    and prof.id = g.target_id
  where (p_before is null or g.newest_report_at < p_before)
  order by g.newest_report_at desc
  limit greatest(1, least(p_limit, 100));
end;
$function$;

-- get_feed_ads: comment-only change (video creatives serve in the Currents player).
create or replace function public.get_feed_ads(page_limit integer default 5, freq_cap integer default 3)
returns table(campaign_id uuid, event_id uuid, post_id uuid, creative_id uuid,
              image_url text, headline text, body text, click_url text,
              advertiser_name text)
language sql
stable security definer
set search_path to 'public'
as $function$
  select
    c.id, c.event_id, c.post_id,
    cr.id, cr.image_url, cr.headline, cr.body, cr.click_url,
    a.name
  from ad_campaigns c
  left join ad_creatives       cr on cr.campaign_id = c.id
  left join ad_targeting       t  on t.campaign_id  = c.id
  left join advertiser_accounts a  on a.id          = c.advertiser_account_id
  where c.status = 'active'
    and now() between c.starts_at and c.ends_at
    and c.spent_cents < c.budget_cents
    -- A standalone campaign (no event/post) must carry a creative to serve.
    and (c.event_id is not null or c.post_id is not null or cr.id is not null)
    -- 0068: video creatives serve only in the Currents player.
    and (cr.id is null or cr.kind = 'image')
    -- Topic targeting: if topic_ids is set, require overlap with the viewer's
    -- interests; untargeted (empty/null) campaigns serve broadly.
    and (
      t.topic_ids is null
      or cardinality(t.topic_ids) = 0
      or auth.uid() is null
      or exists (
        select 1 from user_topics ut
        where ut.user_id = auth.uid()
          and ut.topic_id = any (t.topic_ids)
      )
    )
    -- frequency cap: skip campaigns this viewer has seen >= freq_cap times today
    and (
      auth.uid() is null
      or (
        select count(*) from ad_events ae
        where ae.campaign_id = c.id
          and ae.viewer_id = auth.uid()
          and ae.kind = 'impression'
          and ae.created_at >= date_trunc('day', now())
      ) < freq_cap
    )
    -- viewer said "not interested" — permanent exclusion for that viewer
    and (
      auth.uid() is null
      or not exists (
        select 1 from ad_events ni
        where ni.campaign_id = c.id
          and ni.viewer_id = auth.uid()
          and ni.kind = 'not_interested'
      )
    )
    -- viewer reported this ad — permanent exclusion for that viewer
    and (
      auth.uid() is null
      or not exists (
        select 1 from reports r
        where r.reporter_id = auth.uid()
          and r.target_type = 'ad'
          and r.target_id = c.id
      )
    )
    -- block exclusion: host-boost (advertiser_id) or standalone (account's linked
    -- profile, if any). A standalone account with no linked profile can't be blocked.
    and not exists (
      select 1 from blocks b, lateral (select coalesce(c.advertiser_id, a.profile_id) as adv) z
      where z.adv is not null and (
        (b.blocker_id = auth.uid() and b.blocked_id = z.adv)
        or (b.blocked_id = auth.uid() and b.blocker_id = z.adv)
      )
    )
    -- a promoted event must still be live/scheduled (not ended/draft)
    and (c.event_id is null or exists (
      select 1 from events e
      where e.id = c.event_id and e.status in ('scheduled','live','soundcheck')
    ))
  order by c.starts_at desc
  limit page_limit;
$function$;

-- ── 12. Purge cron job ───────────────────────────────────────────────────────
select cron.unschedule('purge-expired-rapids');
select cron.schedule('purge-expired-currents', '20 4 * * *', $cron$ select public.purge_expired_currents(30); $cron$);

commit;
