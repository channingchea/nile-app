-- 0130a: studio_graphic_payload_ok returned NULL (not false) when a required
-- field was missing — jsonb_typeof(NULL) is NULL — and a CHECK constraint
-- treats NULL as a pass. Coalesce so a missing field fails the check.
create or replace function public.studio_graphic_payload_ok(k public.studio_graphic_kind, p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'object' and case k
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
  end, false)
$$;
