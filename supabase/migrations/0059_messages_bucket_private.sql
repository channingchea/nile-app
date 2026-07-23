-- 0059: Security hardening fix #3 — DM image attachments are no longer
-- world-readable. The messages bucket becomes private and loses its public
-- SELECT policy (which also enabled listing). Participants get short-lived
-- signed URLs from the dm-image-url edge function (service role), which
-- verifies the requester is a participant of the message's conversation.
-- Upload/delete policies are unchanged (authenticated write, owner delete).

update storage.buckets set public = false where id = 'messages';

drop policy if exists messages_storage_public_read on storage.objects;
