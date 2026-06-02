import 'block_service.dart';
import 'event_service.dart';
import 'pagination.dart';
import 'post_service.dart';
import 'profile_service.dart';
import 'supabase_client.dart';

class SearchService {
  /// PostgREST value list for a `not(col, 'in', ...)` filter, or null if empty.
  /// `profiles` has no block-aware RLS, so the People tab MUST filter here;
  /// posts/events also filter as defense-in-depth + to skip RLS-hidden rows.
  static String? _notInList(List<String> ids) =>
      ids.isEmpty ? null : '(${ids.join(',')})';
  // ── Users (offset-paged, ordered by follower_count) ──────────────────────

  /// Full-text search on username and display_name (case-insensitive).
  /// Excludes the signed-in user. Offset-paged via [cursor] (row offset).
  static Future<Paged<UserProfile>> searchUsers(String query,
      {String? cursor}) async {
    final q = query.trim();
    if (q.isEmpty) return Paged.empty();
    final pattern = '%$q%';
    return _pagedProfiles(
      (b) => b.or('username.ilike.$pattern,display_name.ilike.$pattern'),
      cursor: cursor,
    );
  }

  /// Suggested creators ordered by follower count, offset-paged via [cursor].
  /// Excludes the signed-in user.
  static Future<Paged<UserProfile>> suggestedUsers({String? cursor}) =>
      _pagedProfiles((b) => b, cursor: cursor);

  /// Shared offset pagination over `profiles`, ordered by follower_count desc
  /// with id as a stable tiebreaker. [filter] applies any extra constraints.
  ///
  /// Ordering uses the denormalized `follower_count` column, but the displayed
  /// follower counts are recomputed live from the `follows` table (the same
  /// source of truth as the profile page) since that column can drift.
  static Future<Paged<UserProfile>> _pagedProfiles(
    dynamic Function(dynamic builder) filter, {
    String? cursor,
  }) async {
    final myId = supabase.auth.currentUser?.id;
    final offset = int.tryParse(cursor ?? '') ?? 0;

    var b = filter(supabase.from('profiles').select());
    if (myId != null) b = b.neq('id', myId);
    final blocked = _notInList(await BlockService.blockedIds());
    if (blocked != null) b = b.not('id', 'in', blocked);

    final rows = await b
        .order('follower_count', ascending: false)
        .order('id', ascending: true)
        .range(offset, offset + kPageSize - 1);

    var items =
        (rows as List).map((r) => UserProfile.fromMap(r)).toList();
    items = await _withLiveFollowerCounts(items);
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? '${offset + kPageSize}' : null,
    );
  }

  /// Replaces each profile's denormalized follower count with a live count
  /// from the `follows` table, in one query for the whole page.
  static Future<List<UserProfile>> _withLiveFollowerCounts(
    List<UserProfile> users,
  ) async {
    if (users.isEmpty) return users;
    final ids = users.map((u) => u.id).toList();
    final rows = await supabase
        .from('follows')
        .select('following_id')
        .inFilter('following_id', ids);

    final counts = <String, int>{};
    for (final r in rows as List) {
      final id = r['following_id'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return users
        .map((u) => u.copyWith(followerCount: counts[u.id] ?? 0))
        .toList();
  }

  // ── Posts (keyset by created_at) ──────────────────────────────────────────

  /// Search posts by caption/content (case-insensitive), newest first.
  /// Keyset-paged: pass the previous page's [cursor] as `before`.
  static Future<Paged<Post>> searchPosts(String query, {String? cursor}) async {
    final q = query.trim();
    if (q.isEmpty) return Paged.empty();
    var b = supabase
        .from('posts')
        .select('*, profiles!posts_user_id_fkey(username, avatar_url)')
        .ilike('content', '%$q%');
    final myId = supabase.auth.currentUser?.id;
    if (myId != null) b = b.neq('user_id', myId);
    final blocked = _notInList(await BlockService.blockedIds());
    if (blocked != null) b = b.not('user_id', 'in', blocked);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows =
        await b.order('created_at', ascending: false).limit(kPageSize);
    return _pagePosts(rows as List);
  }

  static Paged<Post> _pagePosts(List rows) {
    final items =
        rows.map((r) => Post.fromJson(r as Map<String, dynamic>)).toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor:
          hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  // ── Events (keyset by created_at, then sorted live-first per page) ────────

  /// Search events by title or description (case-insensitive). Excludes ended
  /// events. Keyset-paged by created_at via [cursor].
  static Future<Paged<Event>> searchEvents(String query, {String? cursor}) async {
    final q = query.trim();
    if (q.isEmpty) return Paged.empty();
    final pattern = '%$q%';
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
        .or('title.ilike.$pattern,description.ilike.$pattern')
        .neq('status', 'ended');
    final myId = supabase.auth.currentUser?.id;
    if (myId != null) b = b.neq('host_id', myId);
    final blocked = _notInList(await BlockService.blockedIds());
    if (blocked != null) b = b.not('host_id', 'in', blocked);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows =
        await b.order('created_at', ascending: false).limit(kPageSize);
    return _pageEvents(rows as List);
  }

  /// Discoverable events (all non-ended), keyset-paged by created_at.
  static Future<Paged<Event>> discoverEvents({String? cursor}) async {
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
        .neq('status', 'ended');
    final myId = supabase.auth.currentUser?.id;
    if (myId != null) b = b.neq('host_id', myId);
    final blocked = _notInList(await BlockService.blockedIds());
    if (blocked != null) b = b.not('host_id', 'in', blocked);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows =
        await b.order('created_at', ascending: false).limit(kPageSize);
    return _pageEvents(rows as List);
  }

  static Paged<Event> _pageEvents(List rows) {
    final items =
        rows.map((r) => Event.fromJson(r as Map<String, dynamic>)).toList();
    final hasMore = items.length == kPageSize;
    final nextCursor =
        hasMore ? items.last.createdAt.toIso8601String() : null;
    // Live-first within the page (created_at cursor stays based on raw order).
    items.sort((a, b) {
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    return Paged(items: items, hasMore: hasMore, nextCursor: nextCursor);
  }
}
