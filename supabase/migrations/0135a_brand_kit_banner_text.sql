-- Brand kit: text on the accent colour (the banner) as its own colour, so a
-- bright accent can carry dark text while panels carry light text. Null = the
-- kit's text colour.
alter table public.brand_kits
  add column if not exists accent_text text check (accent_text is null or accent_text ~ '^#[0-9A-Fa-f]{6}$');
