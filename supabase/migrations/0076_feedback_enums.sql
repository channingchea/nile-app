-- 0076: enum + preference groundwork for in-app bug/feature reporting.
--
-- Split from 0077 on purpose: Postgres refuses to USE a newly added enum value
-- in the same transaction that adds it, and 0077's notif_enabled rewrite
-- compares against 'feedback_resolved' inside a SQL-language function (parsed
-- at creation time). Same reason 0066 was split out from 0067.

alter type notification_type add value if not exists 'feedback_resolved';

alter table notification_preferences
  add column if not exists feedback_resolved boolean not null default true;
