import '../router.dart';
import 'event_service.dart';
import 'message_service.dart';
import 'notification_service.dart';
import 'post_service.dart';
import 'profile_service.dart';

/// Where a tap should land: a [NileRoutes] location plus the model that was
/// already fetched to work it out, handed on as go_router `extra` so the
/// destination renders without a second round trip.
class NileDestination {
  final String location;
  final Object? extra;
  const NileDestination(this.location, {this.extra});
}

/// The one place that maps "an entity" to "the screen that shows it".
///
/// Deep links, push-notification taps and the in-app notification list all
/// resolve through here, so a `post_like` opens the post in exactly one way
/// no matter which of the three it arrived by. Callers only decide *how* to
/// navigate: `nileRouter.go` for arrivals from outside the app, `context.push`
/// for taps inside it.
class Destinations {
  Destinations._();

  // ── Entities ───────────────────────────────────────────────────────────────

  /// Null when the post is gone (deleted, or a stale link).
  static Future<NileDestination?> post(String postId) async {
    final post = await PostService.fetchById(postId);
    if (post == null) return null;
    return NileDestination(NileRoutes.post(post.id), extra: post);
  }

  /// An event leads to the live viewer while the show is on air and to the
  /// event page otherwise. Null when the event is gone.
  static Future<NileDestination?> event(String eventId) async {
    final event = await EventService.fetchById(eventId);
    if (event == null) return null;
    final room = event.liveKitEventId;
    return NileDestination(
      // A live event with no LiveKit room can't address /watch/:id, so it falls
      // back to its event page rather than opening a viewer with nothing to
      // join.
      NileRoutes.eventOrWatch(
        isLive: event.isLive && room != null,
        eventId: event.id,
        liveKitEventId: room ?? '',
      ),
      // Ignored by the viewer, which only needs the room id; the event page
      // uses it to skip the refetch.
      extra: event,
    );
  }

  /// Host-only: straight to the pricing screen for this event.
  static Future<NileDestination?> replayPricing(String eventId) async {
    final event = await EventService.fetchById(eventId);
    if (event == null) return null;
    return NileDestination(
      NileRoutes.eventReplayPricing(event.id),
      extra: event,
    );
  }

  static NileDestination profile(String userId) =>
      NileDestination(NileRoutes.profile(userId));

  /// Share links carry a username rather than an id. Null when it matches no
  /// account.
  static Future<NileDestination?> profileByUsername(String username) async {
    final userId = await ProfileService.idForUsername(username);
    return userId == null ? null : profile(userId);
  }

  /// Resolves (or reuses) the conversation with [otherUserId].
  static Future<NileDestination> conversationWith(String otherUserId) async {
    final conversation = await MessageService.getOrCreate(otherUserId);
    return NileDestination(NileRoutes.dm(otherUserId), extra: conversation);
  }

  static NileDestination report(String reportId) =>
      NileDestination(NileRoutes.report(reportId));

  // ── Inbound taps ───────────────────────────────────────────────────────────

  /// A parsed deep link (`{kind, value}`) → destination. `profile` links carry
  /// a username, the others an id.
  static Future<NileDestination?> forLink({
    required String kind,
    required String value,
  }) async {
    switch (kind) {
      case 'post':
        return post(value);
      case 'event':
        return event(value);
      case 'profile':
        return profileByUsername(value);
    }
    return null;
  }

  /// A notification → destination, whether it arrived as an FCM tap or as a row
  /// in the notification list. [entityId] and [actorId] mirror the
  /// `notifications` columns: entity_id is the post/event/report, actor_id the
  /// person who caused it.
  static Future<NileDestination?> forNotification(
    NotificationType type, {
    String? entityId,
    String? actorId,
  }) async {
    switch (type) {
      case NotificationType.postLike:
      case NotificationType.postComment:
        if (entityId == null) return null;
        return post(entityId);
      case NotificationType.follow:
        if (actorId == null) return null;
        return profile(actorId);
      case NotificationType.newMessage:
      case NotificationType.messageReaction:
        // actor_id is the sender/reactor (the other participant); resolve (or
        // reuse) the conversation by it.
        if (actorId == null) return null;
        return conversationWith(actorId);
      case NotificationType.eventStarting:
      case NotificationType.eventLive:
      case NotificationType.eventEnded:
      case NotificationType.eventNoShow:
      case NotificationType.operatorAssigned:
      case NotificationType.replayReady:
      case NotificationType.soundcheckOpen:
        if (entityId == null) return null;
        return event(entityId);
      case NotificationType.replayPricePrompt:
        if (entityId == null) return null;
        return replayPricing(entityId);
      case NotificationType.feedbackResolved:
        if (entityId == null) return null;
        return report(entityId);
    }
  }

  /// FCM `data.type` → [NotificationType]. Strict on purpose: a type with no
  /// screen (`tip_received`) or one added server-side later returns null and
  /// navigates nowhere, rather than falling back to some unrelated screen.
  static NotificationType? typeFromPush(String? raw) => switch (raw) {
    'post_like' => NotificationType.postLike,
    'post_comment' => NotificationType.postComment,
    'follow' => NotificationType.follow,
    'event_starting' => NotificationType.eventStarting,
    'event_live' => NotificationType.eventLive,
    'event_ended' => NotificationType.eventEnded,
    'event_no_show' => NotificationType.eventNoShow,
    'operator_assigned' => NotificationType.operatorAssigned,
    'new_message' => NotificationType.newMessage,
    'message_reaction' => NotificationType.messageReaction,
    'replay_ready' => NotificationType.replayReady,
    'soundcheck_open' => NotificationType.soundcheckOpen,
    'replay_price_prompt' => NotificationType.replayPricePrompt,
    'feedback_resolved' => NotificationType.feedbackResolved,
    _ => null,
  };
}
