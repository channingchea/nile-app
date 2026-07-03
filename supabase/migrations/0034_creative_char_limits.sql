-- Minor findings #6 + #12 (AD_PLATFORM_REVIEW_NOTES.md).
-- #6: canonical creative char limits are headline 60 / body 150 (create-ad-payment
--     and the portal already enforce these; the 0028 CHECKs allowed 80/200).
alter table ad_creatives drop constraint ad_creatives_headline_check;
alter table ad_creatives add constraint ad_creatives_headline_check
  check (char_length(headline) >= 1 and char_length(headline) <= 60);

alter table ad_creatives drop constraint ad_creatives_body_check;
alter table ad_creatives add constraint ad_creatives_body_check
  check (char_length(body) >= 1 and char_length(body) <= 150);

-- #12: server-side limits on the ad-creatives bucket (matches app-wide 5MB kMaxImageBytes).
update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'ad-creatives';
