-- 0154: the Premiere poster's banner crop. The host crops the poster twice:
-- 2:3 for before the film (poster_url) and 16:9 for the event page banner
-- (banner_url). Same rules as poster_url: set only through the premiere
-- function, which only accepts our public events-bucket URLs.
alter table public.event_films
  add column if not exists banner_url text check (char_length(banner_url) <= 1000);
