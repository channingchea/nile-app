-- Brand kit (graphics library expansions, phase 2).
-- One per account: the colours and font every Studio graphic is drawn with,
-- plus a default logo. Owner-only — viewers never read this table; the Studio
-- copies the style into room metadata (`graphics.brand`) when it pushes.
-- Font list mirrors brandFonts (lib/services/brand_kit.dart) and BRAND_FONTS
-- (supabase/functions/_shared/graphics.ts).
create table public.brand_kits (
  owner_id   uuid primary key references public.profiles(id) on delete cascade,
  accent     text not null check (accent ~ '^#[0-9A-Fa-f]{6}$'),
  panel      text not null check (panel ~ '^#[0-9A-Fa-f]{6}$'),
  text_color text not null check (text_color ~ '^#[0-9A-Fa-f]{6}$'),
  font       text check (font in (
    'Inter', 'Montserrat', 'Poppins', 'Oswald', 'Bebas Neue', 'Playfair Display',
    'Merriweather', 'Space Grotesk', 'DM Serif Display', 'Archivo Black',
    'Roboto Slab', 'Caveat')),
  -- studio-graphics bucket, the owner's own folder.
  logo_path  text check (logo_path is null or (char_length(logo_path) <= 300
                          and split_part(logo_path, '/', 1) = owner_id::text)),
  updated_at timestamptz not null default now()
);

alter table public.brand_kits enable row level security;

create policy brand_kits_owner on public.brand_kits
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
