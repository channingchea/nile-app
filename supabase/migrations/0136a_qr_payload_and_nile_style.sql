-- QR payloads + the per-graphic "Use Nile style" opt-out (graphics library
-- expansions, phases 2-3). Same rules as StudioGraphic.validate
-- (lib/services/studio_graphics.dart) and cleanGraphic (_shared/graphics.ts).
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
    and (p->'nileStyle' is null or jsonb_typeof(p->'nileStyle') = 'boolean')
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
    when 'qr' then
      coalesce(p->>'source', 'custom') in ('custom', 'event', 'profile')
      and (coalesce(p->>'source', 'custom') <> 'custom' or (
        jsonb_typeof(p->'url') = 'string'
        and char_length(p->>'url') <= 500
        and p->>'url' ~* '^https://[^\s/$.?#][^\s]*$'))
      and p->>'corner' in ('tl', 'tr', 'bl', 'br')
      and (p->'size' is null or p->>'size' in ('s', 'm', 'l'))
      and (p->'caption' is null or (jsonb_typeof(p->'caption') = 'string' and char_length(p->>'caption') <= 40))
  end, false)
$$;
