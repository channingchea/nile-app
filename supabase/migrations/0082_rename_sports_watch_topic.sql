-- 0082_rename_sports_watch_topic.sql
-- Renames the 'sports' topic bubble label from "Sports Watch" to "Sports Events".
-- Data-only: slug/sort_order/id unchanged, so event_topics/user_topics rows are unaffected.

update public.topics set name = 'Sports Events' where slug = 'sports';
