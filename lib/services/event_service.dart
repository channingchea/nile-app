import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'block_service.dart';
import 'event_repost_service.dart';
import 'like_service.dart';
import 'net.dart';
import 'pagination.dart';
import 'supabase_client.dart';
import 'topic_service.dart';

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
  final bool hostIsOfficial;
  final String title;
  final String? description;
  final String status; // 'scheduled' | 'live' | 'ended'
  final String? liveKitEventId;
  final String? coverImageUrl;
  final int viewerCount;
  final int likeCount;
  final int repostCount;
  final int? price; // cents
  final int? replayPrice; // cents; null = host hasn't priced the replay yet
  final DateTime? replayPublishedAt; // null = replay not published to fans
  final int? ticketLimit;
  final int cameraCount;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? scheduledAt;
  final DateTime? endAt;

  /// Transient — populated client-side via [EventService.hydrateLikes].
  final bool likedByMe;
  final bool repostedByMe;

  /// Transient — set when this event entered a feed via someone's repost.
  final String? repostedByUsername;

  const Event({
    required this.id,
    required this.hostId,
    required this.hostUsername,
    this.hostAvatarUrl,
    this.hostIsOfficial = false,
    required this.title,
    this.description,
    required this.status,
    this.liveKitEventId,
    this.coverImageUrl,
    required this.viewerCount,
    this.likeCount = 0,
    this.repostCount = 0,
    this.price,
    this.replayPrice,
    this.replayPublishedAt,
    this.ticketLimit,
    this.cameraCount = 1,
    required this.createdAt,
    this.startedAt,
    this.scheduledAt,
    this.endAt,
    this.likedByMe = false,
    this.repostedByMe = false,
    this.repostedByUsername,
  });

  Event copyWith({
    int? likeCount,
    int? repostCount,
    bool? likedByMe,
    bool? repostedByMe,
    String? repostedByUsername,
  }) {
    return Event(
      id: id,
      hostId: hostId,
      hostUsername: hostUsername,
      hostAvatarUrl: hostAvatarUrl,
      hostIsOfficial: hostIsOfficial,
      title: title,
      description: description,
      status: status,
      liveKitEventId: liveKitEventId,
      coverImageUrl: coverImageUrl,
      viewerCount: viewerCount,
      likeCount: likeCount ?? this.likeCount,
      repostCount: repostCount ?? this.repostCount,
      price: price,
      replayPrice: replayPrice,
      replayPublishedAt: replayPublishedAt,
      ticketLimit: ticketLimit,
      cameraCount: cameraCount,
      createdAt: createdAt,
      startedAt: startedAt,
      scheduledAt: scheduledAt,
      endAt: endAt,
      likedByMe: likedByMe ?? this.likedByMe,
      repostedByMe: repostedByMe ?? this.repostedByMe,
      repostedByUsername: repostedByUsername ?? this.repostedByUsername,
    );
  }

  /// Convenience for legacy callers; cover photo is the event thumbnail.
  String? get thumbnailUrl => coverImageUrl;

  bool get isLive => status == 'live';
  bool get isSoundCheck => status == 'soundcheck';
  bool get isScheduled => status == 'scheduled';
  bool get isEnded => status == 'ended';
  bool get isDraft => status == 'draft';

  factory Event.fromJson(
    Map<String, dynamic> json, {
    String? repostedByUsername,
  }) {
    final profile = (json['profiles'] as Map<String, dynamic>?) ?? {};
    return Event(
      id: json['id'] as String,
      hostId: json['host_id'] as String,
      hostUsername: profile['username'] as String? ?? 'unknown',
      hostAvatarUrl: profile['avatar_url'] as String?,
      hostIsOfficial: profile['is_official'] as bool? ?? false,
      title: json['title'] as String,
      description: json['description'] as String?,
      status: json['status'] as String,
      liveKitEventId: json['livekit_room'] as String?,
      coverImageUrl:
          (json['cover_image_url'] ?? json['thumbnail_url']) as String?,
      viewerCount: (json['viewer_count'] as num?)?.toInt() ?? 0,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      repostCount: (json['repost_count'] as num?)?.toInt() ?? 0,
      repostedByUsername: repostedByUsername,
      price: (json['price'] as num?)?.toInt(),
      replayPrice: (json['replay_price'] as num?)?.toInt(),
      replayPublishedAt: json['replay_published_at'] != null
          ? DateTime.parse(json['replay_published_at'] as String)
          : null,
      ticketLimit: (json['ticket_limit'] as num?)?.toInt(),
      cameraCount: (json['camera_count'] as num?)?.toInt() ?? 1,
      createdAt: DateTime.parse(json['created_at'] as String),
      startedAt: json['started_at'] != null
          ? DateTime.parse(json['started_at'] as String)
          : null,
      scheduledAt: json['scheduled_at'] != null
          ? DateTime.parse(json['scheduled_at'] as String)
          : null,
      endAt: json['end_at'] != null
          ? DateTime.parse(json['end_at'] as String)
          : null,
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class EventService {
  /// PostgREST value list for a `not(col,'in',...)` filter, or null if empty.
  static String? _notInList(List<String> ids) =>
      ids.isEmpty ? null : '(${ids.join(',')})';

  /// Live events across the whole platform (not follow-scoped), most-watched
  /// first. Powers the zero-follow starter feed and the Live Now rail.
  /// Excludes the caller's own events and blocked hosts.
  static Future<List<Event>> getLiveNow({int limit = 20}) => guard(() async {
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .eq('status', 'live');
    final myId = supabase.auth.currentUser?.id;
    if (myId != null) b = b.neq('host_id', myId);
    final blocked = _notInList(await BlockService.blockedIds());
    if (blocked != null) b = b.not('host_id', 'in', blocked);
    final rows = await b.order('viewer_count', ascending: false).limit(limit);
    return (rows as List)
        .map((r) => Event.fromJson(r as Map<String, dynamic>))
        .toList();
  });

  /// Upcoming scheduled events across the platform, soonest-first — the
  /// cold-start workhorse (scheduled shows exist before social content does).
  /// Only future-scheduled, non-ended, non-draft events; excludes the caller
  /// and blocked hosts.
  static Future<List<Event>> getUpcoming({int limit = 20}) => guard(() async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .neq('status', 'ended')
        .neq('status', 'draft')
        .gte('scheduled_at', nowIso);
    final myId = supabase.auth.currentUser?.id;
    if (myId != null) b = b.neq('host_id', myId);
    final blocked = _notInList(await BlockService.blockedIds());
    if (blocked != null) b = b.not('host_id', 'in', blocked);
    final rows = await b.order('scheduled_at', ascending: true).limit(limit);
    return (rows as List)
        .map((r) => Event.fromJson(r as Map<String, dynamic>))
        .toList();
  });

  /// Feed: every event from [followingIds] that hasn't passed yet, live-first.
  ///
  /// "Passed" = status is `ended`, OR it was scheduled and the scheduled time
  /// is already in the past (host no-show). Events with no scheduled_at are
  /// treated as evergreen posts and remain visible until they end.
  static Future<Paged<Event>> getFeed(
    List<String> followingIds, {
    String? cursor,
  }) => guard(() async {
    if (followingIds.isEmpty) return Paged.empty();

    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .inFilter('host_id', followingIds)
        .neq('status', 'ended')
        .neq('status', 'draft');
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);

    final raw = (rows as List).map(
      (r) => Event.fromJson(r as Map<String, dynamic>),
    );
    // hasMore / cursor are based on the raw page (before no-show filtering) so
    // paging stays correct even when items are dropped.
    final fetched = raw.toList();
    final hasMore = fetched.length == kPageSize;
    final nextCursor = hasMore
        ? fetched.last.createdAt.toIso8601String()
        : null;

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
  });

  /// All published events from a single host (newest first), excluding drafts.
  /// Used by public profile pages. Keyset-paged by created_at via [cursor].
  static Future<Paged<Event>> getEventsByHost(
    String hostId, {
    String? cursor,
    int limit = kPageSize,
  }) async {
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .eq('host_id', hostId)
        .neq('status', 'draft');
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(limit);

    final items = (rows as List)
        .map((r) => Event.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == limit;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  /// The current user's draft events (newest first). Owner-only — RLS scopes
  /// draft visibility to the host, so this only ever returns the caller's own
  /// drafts. Used by the Drafts tab on the profile page.
  static Future<Paged<Event>> getDrafts({
    String? cursor,
    int limit = kPageSize,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return Paged.empty();
    var b = supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .eq('host_id', uid)
        .eq('status', 'draft');
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(limit);

    final items = (rows as List)
        .map((r) => Event.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == limit;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  /// Publish a draft: flip its status to 'scheduled' (host only, RLS-enforced).
  static Future<Event> publishDraft(String eventId) async {
    final row = await supabase
        .from('events')
        .update({'status': 'scheduled'})
        .eq('id', eventId)
        .eq('status', 'draft')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .single();
    return Event.fromJson(row);
  }

  /// Persist a newly created event to Supabase after the LiveKit backend call.
  /// Returns the inserted row (with host profile joined) so callers can use
  /// the generated event id — the multi-page create flow needs it for crew
  /// assignment and the summary/detail link.
  static Future<Event> create({
    required String title,
    required String liveKitEventId,
    String? description,
    String? coverImageUrl,
    DateTime? scheduledAt,
    DateTime? endAt,
    int? price, // cents
    int? ticketLimit,
    int? cameraCount,
    bool asDraft = false,
    List<String>? topicIds,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('EventService: no authenticated user');

    final row = await supabase
        .from('events')
        .insert({
          'host_id': uid,
          'title': title,
          'livekit_room': liveKitEventId,
          if (asDraft) 'status': 'draft',
          if (description != null && description.isNotEmpty)
            'description': description,
          'cover_image_url': ?coverImageUrl,
          // toUtc() so the ISO string carries the offset — otherwise Postgres
          // reads a local wall-clock time as UTC and every display is skewed.
          if (scheduledAt != null)
            'scheduled_at': scheduledAt.toUtc().toIso8601String(),
          if (endAt != null) 'end_at': endAt.toUtc().toIso8601String(),
          'price': ?price,
          'ticket_limit': ?ticketLimit,
          'camera_count': ?cameraCount,
        })
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .single();
    final event = Event.fromJson(row);
    if (topicIds != null && topicIds.isNotEmpty) {
      await TopicService.setEventTopics(event.id, topicIds);
    }
    return event;
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
    DateTime? endAt,
    bool clearEndAt = false,
    int? price,
    bool clearPrice = false,
    int? ticketLimit,
    bool clearTicketLimit = false,
    int? cameraCount,
    List<String>? topicIds, // null = leave tags untouched; [] = clear all
  }) async {
    if (topicIds != null) {
      await TopicService.setEventTopics(eventId, topicIds);
    }
    final updates = <String, dynamic>{
      'title': ?title,
      'description': ?description,
      'cover_image_url': ?coverImageUrl,
      if (clearCoverImageUrl) 'cover_image_url': null,
      if (scheduledAt != null)
        'scheduled_at': scheduledAt.toUtc().toIso8601String(),
      if (clearScheduledAt) 'scheduled_at': null,
      if (endAt != null) 'end_at': endAt.toUtc().toIso8601String(),
      if (clearEndAt) 'end_at': null,
      'price': ?price,
      if (clearPrice) 'price': null,
      'ticket_limit': ?ticketLimit,
      if (clearTicketLimit) 'ticket_limit': null,
      'camera_count': ?cameraCount,
    };

    // Nothing changed — skip the update and just fetch the current row.
    if (updates.isEmpty) {
      final row = await supabase
          .from('events')
          .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
          .eq('id', eventId)
          .single();
      return Event.fromJson(row);
    }

    final row = await supabase
        .from('events')
        .update(updates)
        .eq('id', eventId)
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .single();

    return Event.fromJson(row);
  }

  /// Delete an event (host only). RLS `events_delete_own` enforces ownership;
  /// tickets cascade via the FK. Best-effort removal of the cover image too.
  static Future<void> deleteEvent(
    String eventId, {
    String? liveKitEventId,
  }) async {
    await supabase.from('events').delete().eq('id', eventId);
    if (liveKitEventId != null) {
      try {
        await supabase.storage.from('events').remove([
          '$liveKitEventId/cover.jpg',
        ]);
      } catch (_) {
        /* cover may not exist — ignore */
      }
    }
  }

  /// Upload a cover image for an event and return its public URL.
  /// Stored at `events/{liveKitEventId}/cover.jpg` in the `events` bucket.
  static Future<String> uploadCoverBytes({
    required String liveKitEventId,
    required Uint8List bytes,
  }) async {
    final path = '$liveKitEventId/cover.jpg';
    await supabase.storage
        .from('events')
        .uploadBinary(
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
    final liked = await LikeService.getLikedEventIds(
      events.map((e) => e.id).toList(),
    );
    return events
        .map((e) => e.copyWith(likedByMe: liked.contains(e.id)))
        .toList();
  }

  /// Sets [Event.repostedByMe] for every event in one round-trip.
  static Future<List<Event>> hydrateReposts(List<Event> events) async {
    if (events.isEmpty) return events;
    final reposted = await EventRepostService.getRepostedEventIds(
      events.map((e) => e.id).toList(),
    );
    return events
        .map((e) => e.copyWith(repostedByMe: reposted.contains(e.id)))
        .toList();
  }

  /// Reposts made by [reposterIds], newest-repost-first, each hydrated as the
  /// original [Event] with [Event.repostedByUsername] set. Returns (event,
  /// repostedAt) pairs so the feed can sort by repost time. Mirrors
  /// [PostService.getRepostsFeed].
  static Future<List<({Event event, DateTime repostedAt})>> getRepostsFeed(
    List<String> reposterIds, {
    int limit = kPageSize,
  }) async {
    if (reposterIds.isEmpty) return const [];
    final rows = await supabase
        .from('event_reposts')
        .select(
          'created_at, reposter:profiles!event_reposts_user_id_fkey(username), '
          'event:events!event_reposts_event_id_fkey('
          '*, profiles!events_host_id_fkey(username, avatar_url, is_official))',
        )
        .inFilter('user_id', reposterIds)
        .order('created_at', ascending: false)
        .limit(limit);
    final out = <({Event event, DateTime repostedAt})>[];
    for (final r in rows as List) {
      final m = r as Map<String, dynamic>;
      final ev = m['event'] as Map<String, dynamic>?;
      if (ev == null) continue;
      final reposter = (m['reposter'] as Map<String, dynamic>?) ?? {};
      out.add((
        event: Event.fromJson(
          ev,
          repostedByUsername: reposter['username'] as String?,
        ),
        repostedAt: DateTime.parse(m['created_at'] as String),
      ));
    }
    return out;
  }

  /// Fetch a full event by id with host profile joined.
  static Future<Event?> fetchById(String eventId) async {
    final rows = await supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .eq('id', eventId)
        .limit(1);
    final list = rows as List;
    return list.isEmpty
        ? null
        : Event.fromJson(list.first as Map<String, dynamic>);
  }

  /// Subscribe to realtime updates on an event row by its primary id.
  /// Mirror of [subscribeToEvent] but keyed on `id` for detail screens.
  static RealtimeChannel subscribeToEventById({
    required String eventId,
    required void Function(Map<String, dynamic> record) onUpdate,
    void Function(RealtimeSubscribeStatus status, Object? error)? onStatus,
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
        .subscribe(onStatus);
  }

  /// Transition an event to 'soundcheck' — host/operators are connected and
  /// testing devices; viewers wait in the Lobby until 'live'. No-op if the row
  /// is already live (don't pull a started show back into soundcheck).
  static Future<void> enterSoundCheck(String liveKitEventId) async {
    await supabase
        .from('events')
        .update({'status': 'soundcheck'})
        .eq('livekit_room', liveKitEventId)
        .neq('status', 'live')
        .neq('status', 'ended');
  }

  /// Ping assigned crew that sound check is open. Server verifies the caller is
  /// the host and dedupes per event, so it's safe to call on every host entry.
  static Future<void> notifySoundcheckOpen(String liveKitEventId) async {
    await supabase.rpc(
      'notify_soundcheck_open',
      params: {'p_livekit_room': liveKitEventId},
    );
  }

  /// Revert a never-started event from 'soundcheck' back to 'scheduled' (host
  /// left during setup without pressing Start Show). Guarded so a live or ended
  /// event is never dragged backwards.
  static Future<void> revertToScheduled(String liveKitEventId) async {
    await supabase
        .from('events')
        .update({'status': 'scheduled'})
        .eq('livekit_room', liveKitEventId)
        .eq('status', 'soundcheck');
  }

  /// Transition an event to 'live'.
  static Future<void> goLive(String liveKitEventId) async {
    await supabase
        .from('events')
        .update({
          'status': 'live',
          'started_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('livekit_room', liveKitEventId);
  }

  /// Transition an event to 'ended'.
  static Future<void> end(String liveKitEventId) async {
    await supabase
        .from('events')
        .update({
          'status': 'ended',
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('livekit_room', liveKitEventId);
  }

  /// Host: publish the replay at [priceCents] (0 = free). Server-side RPC
  /// (migration 0049) verifies the caller is the host, locks the price, stamps
  /// replay_published_at, and fans out replay_ready to fans. Idempotent.
  static Future<void> publishReplay(String eventId, int priceCents) => guard(
    () => supabase.rpc(
      'publish_replay',
      params: {'p_event_id': eventId, 'p_price_cents': priceCents},
    ),
  );

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

  /// Fetch current viewer_count, status, and scheduled_at for an event by
  /// liveKitEventId. scheduled_at gates how early a host may enter sound check.
  static Future<Map<String, dynamic>?> fetchEventState(
    String liveKitEventId,
  ) => guard(() async {
    final rows = await supabase
        .from('events')
        .select('id, host_id, title, viewer_count, status, scheduled_at')
        .eq('livekit_room', liveKitEventId)
        .limit(1);
    return rows.isNotEmpty ? rows.first : null;
  });

  /// Subscribe to realtime updates on an event row.
  /// [onUpdate] receives the raw updated record (viewer_count, status, etc.).
  /// Call [RealtimeChannel.unsubscribe] on the returned channel to clean up.
  static RealtimeChannel subscribeToEvent({
    required String liveKitEventId,
    required void Function(Map<String, dynamic> record) onUpdate,
    void Function(RealtimeSubscribeStatus status, Object? error)? onStatus,
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
        .subscribe(onStatus);
  }
}
