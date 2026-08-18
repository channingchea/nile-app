import 'supabase_client.dart';

/// The current user's per-type notification toggles. Missing row = all enabled.
class NotificationPreferences {
  final bool postLike;
  final bool postComment;
  final bool follow;
  final bool eventStarting;
  final bool eventLive;
  final bool eventEnded;
  final bool operatorAssigned;
  final bool newMessage;
  final bool messageReaction;
  final bool replayReady;
  final bool soundcheckOpen;
  final bool replayPricePrompt;
  final bool feedbackResolved;

  /// P4 #38: this column has existed and been honoured by the server since
  /// tipping shipped — the switch just never made it into the screen, so a
  /// host taking tips through a three-hour show got a push per tip and no way
  /// to stop it.
  final bool tipReceived;

  /// Quiet hours, as local wall-clock times. Both null = off; they are only
  /// ever set or cleared together.
  ///
  /// [quietHoursUtcOffsetMinutes] is a plain offset rather than an IANA zone
  /// (see migration 0127) — the screen refreshes it on open, so a DST change
  /// costs at most an hour of drift until the next visit.
  final int? quietHoursStartMinutes;
  final int? quietHoursEndMinutes;
  final int quietHoursUtcOffsetMinutes;

  /// Covers BOTH `sponsorship_offer` and `sponsorship_offer_expiring` — the
  /// server's `notif_enabled` maps the two types onto this one column, so the
  /// reminder can't outlive the thing it's reminding you about.
  final bool sponsorshipOffer;

  const NotificationPreferences({
    this.postLike = true,
    this.postComment = true,
    this.follow = true,
    this.eventStarting = true,
    this.eventLive = true,
    this.eventEnded = true,
    this.operatorAssigned = true,
    this.newMessage = true,
    this.messageReaction = true,
    this.replayReady = true,
    this.soundcheckOpen = true,
    this.replayPricePrompt = true,
    this.feedbackResolved = true,
    this.sponsorshipOffer = true,
    this.tipReceived = true,
    this.quietHoursStartMinutes,
    this.quietHoursEndMinutes,
    this.quietHoursUtcOffsetMinutes = 0,
  });

  bool get quietHoursOn =>
      quietHoursStartMinutes != null && quietHoursEndMinutes != null;

  factory NotificationPreferences.fromJson(Map<String, dynamic> j) =>
      NotificationPreferences(
        postLike: j['post_like'] as bool? ?? true,
        postComment: j['post_comment'] as bool? ?? true,
        follow: j['follow'] as bool? ?? true,
        eventStarting: j['event_starting'] as bool? ?? true,
        eventLive: j['event_live'] as bool? ?? true,
        eventEnded: j['event_ended'] as bool? ?? true,
        operatorAssigned: j['operator_assigned'] as bool? ?? true,
        newMessage: j['new_message'] as bool? ?? true,
        messageReaction: j['message_reaction'] as bool? ?? true,
        replayReady: j['replay_ready'] as bool? ?? true,
        soundcheckOpen: j['soundcheck_open'] as bool? ?? true,
        replayPricePrompt: j['replay_price_prompt'] as bool? ?? true,
        feedbackResolved: j['feedback_resolved'] as bool? ?? true,
        sponsorshipOffer: j['sponsorship_offer'] as bool? ?? true,
        tipReceived: j['tip_received'] as bool? ?? true,
        quietHoursStartMinutes: _minutesFromSql(j['quiet_hours_start']),
        quietHoursEndMinutes: _minutesFromSql(j['quiet_hours_end']),
        quietHoursUtcOffsetMinutes:
            j['quiet_hours_utc_offset_minutes'] as int? ?? 0,
      );

  /// Postgres `time` arrives as 'HH:MM:SS'. Null stays null — that's "off",
  /// not midnight, and conflating the two would silence every push.
  static int? _minutesFromSql(Object? v) {
    if (v is! String || v.isEmpty) return null;
    final parts = v.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  static String? _sqlFromMinutes(int? mins) => mins == null
      ? null
      : '${(mins ~/ 60).toString().padLeft(2, '0')}:'
          '${(mins % 60).toString().padLeft(2, '0')}:00';

  NotificationPreferences copyWith({
    bool? postLike,
    bool? postComment,
    bool? follow,
    bool? eventStarting,
    bool? eventLive,
    bool? eventEnded,
    bool? operatorAssigned,
    bool? newMessage,
    bool? messageReaction,
    bool? replayReady,
    bool? soundcheckOpen,
    bool? replayPricePrompt,
    bool? feedbackResolved,
    bool? sponsorshipOffer,
    bool? tipReceived,
    int? quietHoursStartMinutes,
    int? quietHoursEndMinutes,
    int? quietHoursUtcOffsetMinutes,
    // copyWith can't express "set this back to null" with optional params, so
    // clearing quiet hours needs its own flag rather than a silent no-op.
    bool clearQuietHours = false,
  }) => NotificationPreferences(
    postLike: postLike ?? this.postLike,
    postComment: postComment ?? this.postComment,
    follow: follow ?? this.follow,
    eventStarting: eventStarting ?? this.eventStarting,
    eventLive: eventLive ?? this.eventLive,
    eventEnded: eventEnded ?? this.eventEnded,
    operatorAssigned: operatorAssigned ?? this.operatorAssigned,
    newMessage: newMessage ?? this.newMessage,
    messageReaction: messageReaction ?? this.messageReaction,
    replayReady: replayReady ?? this.replayReady,
    soundcheckOpen: soundcheckOpen ?? this.soundcheckOpen,
    replayPricePrompt: replayPricePrompt ?? this.replayPricePrompt,
    feedbackResolved: feedbackResolved ?? this.feedbackResolved,
    sponsorshipOffer: sponsorshipOffer ?? this.sponsorshipOffer,
    tipReceived: tipReceived ?? this.tipReceived,
    quietHoursStartMinutes: clearQuietHours
        ? null
        : (quietHoursStartMinutes ?? this.quietHoursStartMinutes),
    quietHoursEndMinutes: clearQuietHours
        ? null
        : (quietHoursEndMinutes ?? this.quietHoursEndMinutes),
    quietHoursUtcOffsetMinutes:
        quietHoursUtcOffsetMinutes ?? this.quietHoursUtcOffsetMinutes,
  );

  Map<String, dynamic> toColumns() => {
    'post_like': postLike,
    'post_comment': postComment,
    'follow': follow,
    'event_starting': eventStarting,
    'event_live': eventLive,
    'event_ended': eventEnded,
    'operator_assigned': operatorAssigned,
    'new_message': newMessage,
    'message_reaction': messageReaction,
    'replay_ready': replayReady,
    'soundcheck_open': soundcheckOpen,
    'replay_price_prompt': replayPricePrompt,
    'feedback_resolved': feedbackResolved,
    'sponsorship_offer': sponsorshipOffer,
    'tip_received': tipReceived,
    'quiet_hours_start': _sqlFromMinutes(quietHoursStartMinutes),
    'quiet_hours_end': _sqlFromMinutes(quietHoursEndMinutes),
    'quiet_hours_utc_offset_minutes': quietHoursUtcOffsetMinutes,
  };
}

class NotificationPreferencesService {
  /// Fetch the current user's preferences. Returns all-on defaults if no row.
  static Future<NotificationPreferences> get() async {
    final uid = _requireUid();
    final row = await supabase
        .from('notification_preferences')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    return row == null
        ? const NotificationPreferences()
        : NotificationPreferences.fromJson(row);
  }

  /// Upsert the full preference set for the current user.
  static Future<void> save(NotificationPreferences prefs) async {
    final uid = _requireUid();
    await supabase.from('notification_preferences').upsert({
      'user_id': uid,
      ...prefs.toColumns(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('NotificationPreferencesService: no authenticated user');
    }
    return uid;
  }
}
