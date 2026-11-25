-- 0132: Studio graphics — auto-hide and countdown modes (studio-edits plan,
-- phase 3). Widens studio_graphic_payload_ok:
--   any kind   autoHideSeconds? (1-3600) — saved default; overridable at push
--   slate      countdown? {mode: duration, seconds 1-86400}
--                       | {mode: clock, at: "HH:MM"}
--                       | {mode: showStart}
-- The legacy countdownSeconds stays valid (it means mode: duration).
create or replace function public.studio_graphic_payload_ok(k public.studio_graphic_kind, p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'object'
    and (p->'autoHideSeconds' is null or (
      jsonb_typeof(p->'autoHideSeconds') = 'number'
      and (p->>'autoHideSeconds')::numeric between 1 and 3600))
    and case k
    when 'lower_third' then
      jsonb_typeof(p->'title') = 'string'
      and char_length(p->>'title') between 1 and 60
      and (p->'subtitle' is null or (jsonb_typeof(p->'subtitle') = 'string' and char_length(p->>'subtitle') <= 80))
    when 'logo' then
      jsonb_typeof(p->'imagePath') = 'string'
      and char_length(p->>'imagePath') between 1 and 300
      and p->>'corner' in ('tl', 'tr', 'bl', 'br')
      and (p->'size' is null or p->>'size' in ('s', 'm', 'l'))
    when 'banner' then
      jsonb_typeof(p->'text') = 'string'
      and char_length(p->>'text') between 1 and 140
      and jsonb_typeof(p->'scrolling') = 'boolean'
    when 'slate' then
      jsonb_typeof(p->'title') = 'string'
      and char_length(p->>'title') between 1 and 60
      and (p->'subtitle' is null or (jsonb_typeof(p->'subtitle') = 'string' and char_length(p->>'subtitle') <= 120))
      and (p->'imagePath' is null or (jsonb_typeof(p->'imagePath') = 'string' and char_length(p->>'imagePath') <= 300))
      and (p->'countdownSeconds' is null or (
        jsonb_typeof(p->'countdownSeconds') = 'number'
        and (p->>'countdownSeconds')::numeric between 1 and 86400))
      and (p->'countdown' is null or (
        jsonb_typeof(p->'countdown') = 'object'
        and case p->'countdown'->>'mode'
          when 'duration' then
            jsonb_typeof(p->'countdown'->'seconds') = 'number'
            and (p->'countdown'->>'seconds')::numeric between 1 and 86400
          when 'clock' then
            coalesce(p->'countdown'->>'at' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$', false)
          when 'showStart' then true
          else false
        end))
  end, false)
$$;
