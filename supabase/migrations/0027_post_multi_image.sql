-- Multi-image posts: up to 5 images per post.
-- image_urls is the source of truth; image_url stays as a mirror of the first
-- image for legacy clients/rows. Backfill existing single-image posts.

alter table public.posts
  add column if not exists image_urls text[];

update public.posts
  set image_urls = array[image_url]
  where image_url is not null
    and image_url <> ''
    and image_urls is null;

alter table public.posts
  add constraint posts_image_urls_max_5
  check (image_urls is null or array_length(image_urls, 1) <= 5);
