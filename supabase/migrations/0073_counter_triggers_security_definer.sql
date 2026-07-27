-- 0073: counter triggers were running as the caller, so their UPDATE hit RLS
-- and silently matched zero rows (currents has no UPDATE policy; profiles only
-- allows updating your own row). Likes/comments/views on Currents never counted,
-- and follower_count drifted (the followee's row could never be bumped).
-- The post/event equivalents were already security definer — this brings the
-- rest in line, then backfills the drift.

create or replace function public.bump_current_like_count()
returns trigger
language plpgsql
security definer
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

create or replace function public.bump_current_comment_count()
returns trigger
language plpgsql
security definer
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

create or replace function public.bump_current_view_count()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
begin
  update currents set view_count = view_count + 1 where id = new.current_id;
  return new;
end;
$function$;

create or replace function public.update_follow_counts()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'INSERT' then
    update profiles set follower_count  = follower_count  + 1 where id = new.following_id;
    update profiles set following_count = following_count + 1 where id = new.follower_id;
  elsif tg_op = 'DELETE' then
    update profiles set follower_count  = greatest(0, follower_count  - 1) where id = old.following_id;
    update profiles set following_count = greatest(0, following_count - 1) where id = old.follower_id;
  end if;
  return null;
end;
$function$;

-- Backfill everything the broken triggers missed.
update currents c set
  like_count    = (select count(*) from current_likes    l where l.current_id = c.id),
  comment_count = (select count(*) from current_comments m where m.current_id = c.id and m.removed_at is null),
  view_count    = (select count(*) from current_views    v where v.current_id = c.id);

update profiles p set
  follower_count  = (select count(*) from follows f where f.following_id = p.id),
  following_count = (select count(*) from follows f where f.follower_id  = p.id);
