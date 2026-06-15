-- Allow a sender to delete their own messages (hard delete). RLS was enabled
-- on messages with INSERT/SELECT/UPDATE policies but no DELETE policy, so
-- client-side deletes silently affected 0 rows. This adds a sender-only DELETE
-- policy backing the long-press "Delete" action in the conversation screen.
--
-- Delete is permanent and removes the message for both participants; the
-- recipient's open thread drops it live via the realtime DELETE subscription.

create policy messages_delete_own
  on messages
  for delete
  using (sender_id = auth.uid());
