import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'like_service.dart';
import 'pagination.dart';
import 'supabase_client.dart';

// ── Required SQL (run once in Supabase SQL editor) ────────────────────────────
// create or replace function increment_viewer_count(p_livekit_room text)
// returns void language sql as $$
//   update events set viewer_count = viewer_count + 1
//   where livekit_room = p_livekit_room;
// $$;
//
// create or replace function decrement_viewer_count(p_livekit_room text)
// returns void language sql as $$
//   update events set viewer_count = greatest(0, viewer_count - 1)
//   where livekit_room = p_livekit_room;
// $$;
// ─────────────────────────────────────────────────────────────────────────────

// ── Model ─────────────────────────────────────────────────────────────────────

class Event {
  final String id;
  final String hostId;
  final String hostUsername;
  final String? hostAvatarUrl;
  final String title;
  final String? description;
  final String status; // 'scheduled' | 'live' | 'ended'
  final String liveKitEventId;
  final String? coverImageUrl;
  final int viewerCount;
  final int likeCount;
  final int? price;        // cents
  final int? ticketLimit;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? scheduledAt;
  /// Transient — populated client-side via [EventService.hydrateLikes].
  final bool likedByMe;

  const Event({
    required this.id,
    required this.hostId,
    required this.hostUsername,
    this.hostAvatarUrl,
    required this.title,
    this.description,
    required this.status,
    required this.liveKitEventId,
    this.coverImageUrl,
    required this.viewerCount,
    this.likeCount = 0,
    this.price,
    this.ticketLimit,
    required this.createdAt,
    this.startedAt,
    this.scheduledAt,
    this.likedByMe = false,
  });

  Event copyWith({int? likeCount, bool? likedByMe}) {
    return Event(
      id: id,
      hostId: hostId,
      hostUsername: hostUsername,
      hostAvatarUrl: hostAvatarUrl,
      title: title,
      description: description,
      status: status,
      liveKitEventId: liveKitEventId,
      coverImageUrl: coverImageUrl,
      viewerCount: viewerCount,
      likeCount: likeCount ?? this.likeCount,
      price: price,
      ticketLimit: ticketLimit,
      createdAt: createdAt,
      startedAt: startedAt,
      scheduledAt: scheduledAt,
      likedByMe: likedByMe ?? this.likedByMe,
    );
  }

  /// Convenience for legacy callers; cover photo is the event thumbnail.
  String? get thumbnailUrl => coverImageUrl;

  bool get isLive => status == 'live';
  bool get isScheduled => status == 'scheduled';
  bool get isEnded => status == 'ended';

  factory Event.fromJson(Map<String, dynamic> json) {
    final profile = (json['profiles'] as Map<String, dynamic>?) ?? {};
    return Event(
      id: json['id'] as String,
      hostId: json['host_id'] as String,
      hostUsername: profile['username'] as String? ?? 'unknown',
      hostAvatarUrl: profile['avatar_url'] as String?,
      title: json['title'] as String,
      description: json['description'] as String?,
      status: json['status'] as String,
      liveKitEventId: json['livekit_room'] as String,
      coverImageUrl: (json['cover_image_url'] ?? json['thumbnail_url']) as String?,
      viewerCount: (json['viewer_count'] as num?)?.toInt() ?? 0,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toInt(),
      ticketLimit: (json['ticket_limit'] as num?)?.toInt(),
      createdAt: DateTime.parse(json['created_at'] as String),
      startedAt: json['started_at'] != null
          ? DateTime.parse(json['started_at'] as String)
          : null,
      scheduledAt: json['scheduled_at'] != null
          ? DateTime.parse(json['scheduled_at'] as String)
          : null,
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class EventService {
  /// Feed: every event from [followingIds] that hasn't passed yet, live-first.
  ///
  /// "Passed" = status is `ended`, OR it was scheduled and the scheduled time
  /// is already in the past (host no-show). Events with no scheduled_at are
  /// treated as evergreen posts and remain visible until they end.
  static Future<Paged<Event>> getFeed(List<String> followingIds,
      {String? cursor}) async {
    if (followingIds.isEmpty) return Paged.empty();

    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
        .inFilter('host_id', followingIds)
        .neq('status', 'ended');
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows =
        await b.order('created_at', ascending: false).limit(kPageSize);

    final raw =
        (rows as List).map((r) => Event.fromJson(r as Map<String, dynamic>));
    // hasMore / cursor are based on the raw page (before no-show filtering) so
    // paging stays correct even when items are dropped.
    final fetched = raw.toList();
    final hasMore = fetched.length == kPageSize;
    final nextCursor =
        hasMore ? fetched.last.createdAt.toIso8601String() : null;

    final now = DateTime.now();
    final events = fetched.where((e) {
      if (e.isEnded) return false;
      if (e.isScheduled &&
          e.scheduledAt != null &&
          e.scheduledAt!.isBefore(now)) {
        return false;
      }
      return true;
    }).toList();

    // Live first, then upcoming-soonest scheduled, then evergreen by recency.
    events.sort((a, b) {
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      if (a.scheduledAt != null && b.scheduledAt != null) {
        return a.scheduledAt!.compareTo(b.scheduledAt!);
      }
      if (a.scheduledAt != null) return -1;
      if (b.scheduledAt != null) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });

    return Paged(items: events, hasMore: hasMore, nextCursor: nextCursor);
  }

  /// All events from a single host (any status, newest first). Used by
  /// profile pages. Keyset-paged by created_at via [cursor].
  static Future<Paged<Event>> getEventsByHost(String hostId,
      {String? cursor, int limit = kPageSize}) async {
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
        .eq('host_id', hostId);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows =
        await b.order('created_at', ascending: false).limit(limit);

    final items =
        (rows as List).map((r) => Event.fromJson(r as Map<String, dynamic>)).toList();
    final hasMore = items.length == limit;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  /// Persist a newly created event to Supabase after the LiveKit backend call.
  static Future<void> create({
    required String title,
    required String liveKitEventId,
    String? description,
    String? coverImageUrl,
    DateTime? scheduledAt,
    int? price,        // cents
    int? ticketLimit,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('EventService: no authenticated user');

    await supabase.from('events').insert({
      'host_id': uid,
      'title': title,
      'livekit_room': liveKitEventId,
      if (description != null && description.isNotEmpty) 'description': description,
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      if (scheduledAt != null) 'scheduled_at': scheduledAt.toIso8601String(),
      if (price != null) 'price': price,
      if (ticketLimit != null) 'ticket_limit': ticketLimit,
    });
  }

  /// Update mutable fields on an existing event. Only fields you pass are
  /// touched — pass `clearScheduledAt: true` to null out the scheduled time.
  /// RLS (`events_update_own`) enforces that only the host can update.
  static Future<Event> update({
    required String eventId,
    String? title,
    String? description,
    String? coverImageUrl,
    bool clearCoverImageUrl = false,
    DateTime? scheduledAt,
    bool clearScheduledAt = false,
    int? price,
    bool clearPrice = false,
    int? ticketLimit,
    bool clearTicketLimit = false,
  }) async {
    final updates = <String, dynamic>{
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      if (clearCoverImageUrl) 'cover_image_url': null,
      if (scheduledAt != null) 'scheduled_at': scheduledAt.toIso8601String(),
      if (clearScheduledAt) 'scheduled_at': null,
      if (price != null) 'price': price,
      if (clearPrice) 'price': null,
      if (ticketLimit != null) 'ticket_limit': ticketLimit,
      if (clearTicketLimit) 'ticket_limit': null,
    };

    final row = await supabase
        .from('events')
        .update(updates)
        .eq('id', eventId)
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
        .single();

    return Event.fromJson(row);
  }

  /// Delete an event (host only). RLS `events_delete_own` enforces ownership;
  /// tickets cascade via the FK. Best-effort removal of the cover image too.
  static Future<void> deleteEvent(String eventId,
      {String? liveKitEventId}) async {
    await supabase.from('events').delete().eq('id', eventId);
    if (liveKitEventId != null) {
      try {
        await supabase.storage
            .from('events')
            .remove(['$liveKitEventId/cover.jpg']);
      } catch (_) {/* cover may not exist — ignore */}
    }
  }

  /// Upload a cover image for an event and return its public URL.
  /// Stored at `events/{liveKitEventId}/cover.jpg` in the `events` bucket.
  static Future<String> uploadCoverBytes({
    required String liveKitEventId,
    required Uint8List bytes,
  }) async {
    final path = '$liveKitEventId/cover.jpg';
    await supabase.storage.from('events').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    final url = supabase.storage.from('events').getPublicUrl(path);
    return '$url?t=${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Populates [Event.likedByMe] for every event in one round-trip.
  static Future<List<Event>> hydrateLikes(List<Event> events) async {
    if (events.isEmpty) return events;
    final liked =
        await LikeService.getLikedEventIds(events.map((e) => e.id).toList());
    return events
        .map((e) => e.copyWith(likedByMe: liked.contains(e.id)))
        .toList();
  }

  /// Fetch a full event by id with host profile joined.
  static Future<Event?> fetchById(String eventId) async {
    final rows = await supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
        .eq('id', eventId)
        .limit(1);
    final list = rows as List;
    return list.isEmpty ? null : Event.fromJson(list.first as Map<String, dynamic>);
  }

  /// Subscribe to realtime updates on an event row by its primary id.
  /// Mirror of [subscribeToEvent] but keyed on `id` for detail screens.
  static RealtimeChannel subscribeToEventById({
    required String eventId,
    required void Function(Map<String, dynamic> record) onUpdate,
  }) {
    return supabase
        .channel('event_detail:$eventId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: eventId,
          ),
          callback: (payload) => onUpdate(payload.newRecord),
        )
        .subscribe();
  }

  /// Transition an event to 'live'.
  static Future<void> goLive(String liveKitEventId) async {
    await supabase
        .from('events')
        .update({'status': 'live', 'started_at': DateTime.now().toIso8601String()})
        .eq('livekit_room', liveKitEventId);
  }

  /// Transition an event to 'ended'.
  static Future<void> end(String liveKitEventId) async {
    await supabase
        .from('events')
        .update({'status': 'ended', 'ended_at': DateTime.now().toIso8601String()})
        .eq('livekit_room', liveKitEventId);
  }

  /// Atomically increment viewer_count (requires the SQL function above).
  static Future<void> incrementViewerCount(String liveKitEventId) async {
    await supabase.rpc(
      'increment_viewer_count',
      params: {'p_livekit_room': liveKitEventId},
    );
  }

  /// Atomically decrement viewer_count (floor 0, requires the SQL function above).
  static Future<void> decrementViewerCount(String liveKitEventId) async {
    await supabase.rpc(
      'decrement_viewer_count',
      params: {'p_livekit_room': liveKitEventId},
    );
  }

  /// Fetch current viewer_count and status for an event by liveKitEventId.
  static Future<Map<String, dynamic>?> fetchEventState(String liveKitEventId) async {
    final rows = await supabase
        .from('events')
        .select('viewer_count, status')
        .eq('livekit_room', liveKitEventId)
        .limit(1);
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Subscribe to realtime updates on an event row.
  /// [onUpdate] receives the raw updated record (viewer_count, status, etc.).
  /// Call [RealtimeChannel.unsubscribe] on the returned channel to clean up.
  static RealtimeChannel subscribeToEvent({
    required String liveKitEventId,
    required void Function(Map<String, dynamic> record) onUpdate,
  }) {
    return supabase
        .channel('event_updates:$liveKitEventId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'livekit_room',
            value: liveKitEventId,
          ),
          callback: (payload) => onUpdate(payload.newRecord),
        )
        .subscribe();
  }
}
