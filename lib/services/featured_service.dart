import 'block_service.dart';
import 'event_service.dart';
import 'profile_service.dart';
import 'supabase_client.dart';

/// Editorially-curated content for the app's "Picked by the Nile team" rails
/// (Discover + onboarding). Rows live in `featured_content` (migration 0063),
/// written only by admins via the `manage-featured` Edge Function; the app just
/// reads (RLS: authenticated read) and hydrates.
class Featured {
  final List<Event> events;
  final List<UserProfile> creators;
  const Featured({required this.events, required this.creators});

  bool get isEmpty => events.isEmpty && creators.isEmpty;
}

class FeaturedService {
  /// One read of `featured_content`, then two batched hydration queries
  /// (events, creator profiles). Curated `position` order is restored after
  /// each `in`-filter (PostgREST doesn't preserve id-list order). Blocked
  /// hosts/creators are filtered out; the signed-in user is dropped from the
  /// creators rail (no "follow yourself"). Best-effort: returns whatever
  /// hydrates.
  static Future<Featured> getFeatured() async {
    final rows = await supabase
        .from('featured_content')
        .select('kind, target_id, position')
        .order('position', ascending: true);

    final eventIds = <String>[];
    final creatorIds = <String>[];
    for (final r in rows as List) {
      final id = r['target_id'] as String;
      switch (r['kind'] as String) {
        case 'event':
          eventIds.add(id);
        case 'creator':
          creatorIds.add(id);
      }
    }

    final (events, creators) = await (
      _events(eventIds),
      _creators(creatorIds),
    ).wait;
    return Featured(events: events, creators: creators);
  }

  static Future<List<Event>> _events(List<String> ids) async {
    if (ids.isEmpty) return [];
    final blocked = (await BlockService.blockedIds()).toSet();
    final rows = await supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .inFilter('id', ids)
        .neq('status', 'draft');
    var events = (rows as List)
        .map((r) => Event.fromJson(r as Map<String, dynamic>))
        .where((e) => !blocked.contains(e.hostId))
        .toList();
    _restoreOrder(events, ids, (e) => e.id);
    return EventService.hydrateLikes(events);
  }

  static Future<List<UserProfile>> _creators(List<String> ids) async {
    if (ids.isEmpty) return [];
    final myId = supabase.auth.currentUser?.id;
    final blocked = (await BlockService.blockedIds()).toSet();
    final rows = await supabase.from('profiles').select().inFilter('id', ids);
    final creators = (rows as List)
        .map((r) => UserProfile.fromMap(r as Map<String, dynamic>))
        .where((c) => c.id != myId && !blocked.contains(c.id))
        .toList();
    _restoreOrder(creators, ids, (c) => c.id);
    return creators;
  }

  /// Re-sorts [items] into the curated [orderedIds] order (in place).
  static void _restoreOrder<T>(
    List<T> items,
    List<String> orderedIds,
    String Function(T) idOf,
  ) {
    final rank = {for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i};
    items.sort(
      (a, b) => (rank[idOf(a)] ?? 1 << 30).compareTo(rank[idOf(b)] ?? 1 << 30),
    );
  }
}
