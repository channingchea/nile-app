import 'supabase_client.dart';

/// Pointer reposts for events. The `events.repost_count` counter is maintained
/// by SQL triggers. Mirrors [RepostService] for posts.
class EventRepostService {
  static String _uid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('EventRepostService: no authenticated user');
    return uid;
  }

  static Future<void> repost(String eventId) async {
    await supabase
        .from('event_reposts')
        .upsert({'user_id': _uid(), 'event_id': eventId});
  }

  static Future<void> unrepost(String eventId) async {
    await supabase
        .from('event_reposts')
        .delete()
        .eq('user_id', _uid())
        .eq('event_id', eventId);
  }

  /// Returns the subset of [eventIds] the current user has reposted.
  static Future<Set<String>> getRepostedEventIds(List<String> eventIds) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null || eventIds.isEmpty) return <String>{};
    final rows = await supabase
        .from('event_reposts')
        .select('event_id')
        .eq('user_id', uid)
        .inFilter('event_id', eventIds);
    return (rows as List).map((r) => r['event_id'] as String).toSet();
  }
}
