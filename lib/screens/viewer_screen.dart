import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../services/ad_service.dart';
import '../services/chat_service.dart';
import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/profile_service.dart';
import '../services/realtime.dart';
import '../services/share_urls.dart';
import '../services/supabase_client.dart';
import '../services/tip_service.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/nile_desktop.dart';
import '../widgets/rolling_number.dart';
import '../widgets/share_to_sheet.dart';

class ViewerScreen extends StatefulWidget {
  final String? initialEventId;

  const ViewerScreen({super.key, this.initialEventId});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

enum ViewerState { idle, connecting, watching }

class CameraFeed {
  final String identity;
  final String cameraName;
  final VideoTrack? track;

  /// True when this tile is a participant's screen share rather than their
  /// camera. One participant can own two tiles (camera + screen), so feeds
  /// are always matched on identity AND kind — never identity alone.
  final bool isScreenShare;

  CameraFeed({
    required this.identity,
    required this.cameraName,
    this.track,
    this.isScreenShare = false,
  });

  String get displayName =>
      isScreenShare ? '$cameraName — Screen' : cameraName;
}

class _ViewerScreenState extends State<ViewerScreen>
    with WidgetsBindingObserver {
  final _eventIdController = TextEditingController();

  ViewerState _state = ViewerState.idle;
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  final List<CameraFeed> _cameras = [];
  int _focusedIndex = 0;
  String? _errorMessage;

  // Audio management
  final Map<String, RemoteTrackPublication> _audioPublications = {};
  bool _audioEnabled = true;
  String? _masterAudioIdentity;

  // Camera sync. Stream Audio is the zero reference: each camera's video
  // subscribe is held back by (audioJoinedAt - cameraJoinedAt), clamped to
  // [0, 2000]ms, so switchable angles align with the audio timeline. Both
  // anchors are server-stamped (no device clock skew). The room's showStartedAt
  // isn't needed for the math — offsets derive purely from joinedAt deltas.
  static const int _maxSyncDelayMs = 2000;
  int? _audioJoinedAt;

  // Phase 7: viewer count + realtime
  int _viewerCount = 0;
  String? _streamEventId; // liveKitEventId for cleanup
  bool _streamEnded = false;

  // Tipping. Resolved from the event row on connect. _tipPending guards the
  // post-checkout confirm-and-announce on app resume.
  String? _eventDbId;
  String? _eventTitle;
  String? _hostId;
  bool _tipPending = false;
  // True while the room dropped (e.g. all cameras left) but the show is still
  // live in the DB — we hold a "reconnecting" overlay and retry rather than
  // ending. Only an `ended` DB status actually ends the show.
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  // The same rejoin machinery also runs at Start Show — the Lobby token has no
  // subscribe rights — and "the stream dropped" is the wrong thing to say at the
  // moment a show begins. Only the overlay's wording depends on this.
  bool _goingLive = false;
  // Event status drives the Lobby: 'soundcheck' → Lobby, 'live' → stream.
  String? _eventStatus;
  ResilientChannel? _eventConn;
  bool _hasIncrementedViewerCount = false;

  // Pre-Show lobby (0079): event context for the upgraded lobby — cover image,
  // countdown to showtime, host row — plus the sponsor creative when the event
  // is sponsored. The video creative loops muted (tap the speaker to unmute).
  DateTime? _scheduledAt;

  /// Carried purely so [_isOver] can apply the same rule the rest of the app
  /// uses — see [Event.isOverAt].
  DateTime? _endAt;
  String? _coverImageUrl;
  String? _hostUsername;
  String? _hostAvatarUrl;
  LobbySponsorship? _sponsorship;
  VideoPlayerController? _sponsorController;
  bool _sponsorMuted = true;
  bool _lobbyImpressionLogged = false;
  Timer? _lobbyTicker; // 1s countdown refresh while the lobby is showing

  // Periodic server-authoritative viewer-count reconcile. Any watching client
  // re-derives the true count from LiveKit participants, so the number self-heals
  // from killed-app drift instead of relying on matched increment/decrement.
  Timer? _viewerReconcileTimer;

  // Live chat (ephemeral broadcast). Capped in-memory buffer so a session feels
  // populated without persisting anything server-side.
  static const int _maxChatMessages = 200;
  RealtimeChannel? _chatChannel;

  /// Read-only topic carrying server-authored announcements (tips). Clients
  /// have no INSERT grant on it, which is what makes those messages
  /// unforgeable — see migration 0099.
  RealtimeChannel? _systemChannel;
  final List<ChatMessage> _chatMessages = [];
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  String? _myUsername;
  String? _myAvatarUrl;
  bool _chatOpen = false;
  // Desktop gives chat a column of its own, so there is nothing to open or
  // close there. This stands in for "the panel is up" everywhere the open flag
  // drives behaviour (auto-follow, the unread dot) rather than position, and is
  // set from build() — the only place that knows which layout was chosen.
  // Always false on compact, so the phone reads exactly _chatOpen as before.
  bool _chatPinned = false;
  bool _hasUnreadChat = false;
  // Pin-to-bottom: while the user has scrolled up, don't yank them down on a new
  // message — count them and surface a "new messages" pill instead.
  bool _chatAtBottom = true;
  int _pendingChatCount = 0;

  // Tap-to-react emoji bursts. Floating overlay particles + a send throttle so
  // rapid taps can't flood the broadcast channel.
  final List<_FloatingReaction> _reactions = [];
  int _reactionSeq = 0;
  DateTime? _lastReactionSentAt;
  static const List<String> _reactionEmojis = ['❤️', '🔥', '👏', '😂', '🎉'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chatScrollController.addListener(_onChatScroll);
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
      // Auto-join when launched from the feed
      WidgetsBinding.instance.addPostFrameCallback((_) => _joinAsViewer());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the external tip checkout. The announcement itself is the
    // server's job now (stripe-webhook broadcasts when the tip settles), which
    // is what fixed the two failure modes here: a CANCELLED tip used to
    // re-announce this viewer's previous tip, and a tip that settled after they
    // closed the screen was never announced at all. All this does now is clear
    // the pending flag.
    if (state == AppLifecycleState.resumed && _tipPending) {
      _tipPending = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _decrementAndCleanup();
    _eventIdController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  void _decrementAndCleanup() {
    _teardownLobby();
    _viewerReconcileTimer?.cancel();
    _viewerReconcileTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _clearReconnect();
    if (_hasIncrementedViewerCount && _streamEventId != null) {
      // Reconcile excluding ourselves so the count drops even before LiveKit
      // registers our disconnect (covers the last-viewer-leaves case).
      LivekitService.reconcileViewers(
        eventId: _streamEventId!,
        excludeSelf: true,
      ).catchError((_) {});
      _hasIncrementedViewerCount = false;
    }
    _eventConn?.dispose();
    _eventConn = null;
    _chatChannel?.unsubscribe();
    _chatChannel = null;
    _systemChannel?.unsubscribe();
    _systemChannel = null;
  }

  /// Re-pull authoritative event state after a realtime drop/rejoin, so a status
  /// or viewer-count change missed while disconnected is applied on reconnect.
  Future<void> _resyncEventState(String liveKitEventId) async {
    try {
      final state = await EventService.fetchEventState(liveKitEventId);
      if (!mounted || state == null) return;
      _onRealtimeUpdate(state);
    } catch (_) {}
  }

  // ── Pre-Show lobby (0079) ─────────────────────────────────────────────────

  /// Fetches the event's sponsorship (if any), starts the countdown ticker,
  /// and — for a video creative — starts muted looping playback. One
  /// impression is logged per lobby entry: the creative IS the whole screen,
  /// so no visibility detection is needed.
  Future<void> _initLobby() async {
    _lobbyTicker?.cancel();
    _lobbyTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _inLobby) {
        setState(() {}); // refresh the countdown
      }
    });

    final dbId = _eventDbId;
    if (dbId == null) return;
    final spons = await AdService.lobbySponsorship(dbId);
    // Re-checked after the await: a lobby that has since aged out must not log
    // the impression the advertiser is billed for.
    if (!mounted || spons == null || !_inLobby) return;

    VideoPlayerController? controller;
    if (spons.kind == 'video' && spons.videoUrl != null) {
      try {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(spons.videoUrl!),
        );
        await controller.initialize();
        await controller.setLooping(true);
        await controller.setVolume(0); // autoplay muted; tap to unmute
        await controller.play();
      } catch (_) {
        controller?.dispose();
        controller = null; // fall back to the thumb/cover
      }
    }
    if (!mounted || !_inLobby) {
      controller?.dispose();
      return;
    }
    setState(() {
      _sponsorship = spons;
      _sponsorController = controller;
      _sponsorMuted = true;
    });
    if (!_lobbyImpressionLogged) {
      _lobbyImpressionLogged = true;
      AdService.logImpression(spons.campaignId);
    }
  }

  /// Stops the countdown and disposes the sponsor video. Called when the show
  /// goes live (the realtime flip drops everyone into the stream) and on leave.
  void _teardownLobby() {
    _lobbyTicker?.cancel();
    _lobbyTicker = null;
    _sponsorController?.dispose();
    _sponsorController = null;
    _sponsorship = null;
    _lobbyImpressionLogged = false;
  }

  void _toggleSponsorMute() {
    final c = _sponsorController;
    if (c == null) return;
    setState(() => _sponsorMuted = !_sponsorMuted);
    c.setVolume(_sponsorMuted ? 0 : 1);
  }

  Future<void> _openSponsorLink() async {
    final spons = _sponsorship;
    if (spons == null || spons.clickUrl.isEmpty) return;
    AdService.logClick(spons.campaignId);
    final uri = Uri.tryParse(spons.clickUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Parses a timestamp off a raw `events` row into local time. Null-safe and
  /// tolerant of a bad value, because the viewer must still open if one field
  /// is malformed.
  static DateTime? _parseTs(Object? raw) => raw is String
      ? DateTime.tryParse(raw)?.toLocal()
      : null;

  /// True once this show is over, whatever `status` claims — a host no-show
  /// stays `scheduled` and an abandoned Sound Check stays `soundcheck` until the
  /// 5-minute sweep catches up. Same rule the feeds and the event page use.
  bool get _isOver => Event.isOverAt(
    status: _eventStatus ?? '',
    scheduledAt: _scheduledAt,
    endAt: _endAt,
  );

  /// The Pre-Show lobby holds viewers between Sound Check and Start Show.
  ///
  /// Gated on [_isOver] as well as the raw status: an abandoned Sound Check used
  /// to render a countdown, a looping sponsor creative, an open chat, and a
  /// billed advertiser impression — for a show that was never going to happen.
  bool get _inLobby =>
      _eventStatus == 'soundcheck' && !_streamEnded && !_isOver;

  /// "Starts in 2h 14m" → "Starting soon" once showtime passes.
  String get _countdownLabel {
    final at = _scheduledAt;
    if (at == null) return 'Starting soon';
    final diff = at.difference(DateTime.now());
    // Every past time used to collapse to "Starting soon" — the exact string
    // the testers reported, still showing on a show three days gone.
    if (diff.isNegative) {
      return _isOver ? 'This event didn’t take place' : 'Starting soon';
    }
    final d = diff.inDays, h = diff.inHours % 24, m = diff.inMinutes % 60;
    final s = diff.inSeconds % 60;
    if (d > 0) return 'Starts in ${d}d ${h}h';
    if (diff.inHours > 0) return 'Starts in ${h}h ${m}m';
    if (diff.inMinutes > 0) return 'Starts in ${m}m ${s}s';
    return 'Starts in ${s}s';
  }

  // ── Chat ──────────────────────────────────────────────────────────────────

  /// Whether the chat list is on screen — collapsed panel on a phone, pinned
  /// column on a desktop. Everything that reacts to chat being *visible* asks
  /// this; only the phone's slide animation still asks [_chatOpen].
  bool get _chatShowing => _chatOpen || _chatPinned;

  void _onChatMessage(ChatMessage msg) {
    if (!mounted) return;
    // Auto-follow only when the user is already pinned to the bottom (or it's
    // their own message). Otherwise keep their scroll position and count the
    // new message for the "new messages" pill.
    final follow = _chatAtBottom || msg.isMine;
    setState(() {
      _chatMessages.add(msg);
      if (_chatMessages.length > _maxChatMessages) {
        _chatMessages.removeRange(0, _chatMessages.length - _maxChatMessages);
      }
      if (!_chatShowing && !msg.isMine) _hasUnreadChat = true;
      if (_chatShowing && !follow && !msg.isSystem) _pendingChatCount++;
    });
    if (_chatShowing && follow) _scrollChatToBottom();
  }

  void _onChatScroll() {
    if (!_chatScrollController.hasClients) return;
    final pos = _chatScrollController.position;
    // Within 40px of the end counts as "at bottom".
    final atBottom = pos.pixels >= pos.maxScrollExtent - 40;
    if (atBottom != _chatAtBottom) {
      setState(() {
        _chatAtBottom = atBottom;
        if (atBottom) _pendingChatCount = 0;
      });
    }
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.jumpTo(
          _chatScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  void _jumpChatToBottom() {
    setState(() {
      _chatAtBottom = true;
      _pendingChatCount = 0;
    });
    _scrollChatToBottom();
  }

  void _toggleChat() {
    setState(() {
      _chatOpen = !_chatOpen;
      if (_chatOpen) _hasUnreadChat = false;
    });
    if (_chatOpen) _scrollChatToBottom();
  }

  /// Share the stream: DM picker + OS share sheet with the canonical event
  /// link, same flow as sharing from the event page.
  Future<void> _shareStream() async {
    final id = _eventDbId;
    if (id == null) return;
    await ShareToSheet.showEvent(
      context,
      eventId: id,
      shareText: ShareUrls.eventCaption(
        id: id,
        title: _eventTitle ?? 'Live on Nile',
      ),
    );
  }

  Future<void> _sendChat() async {
    final raw = _chatController.text.trim();
    if (raw.isEmpty || _chatChannel == null) return;
    final text = raw.length > 250 ? raw.substring(0, 250) : raw;
    _chatController.clear();
    await ChatService.send(
      _chatChannel!,
      username: _myUsername ?? 'viewer',
      avatarUrl: _myAvatarUrl,
      content: text,
    );
  }

  // ── Reactions ─────────────────────────────────────────────────────────────

  /// Incoming (and self-echoed) emoji burst → spawn a floating particle that
  /// rises and fades, then removes itself.
  void _onReaction(LiveReaction r) {
    if (!mounted) return;
    final id = _reactionSeq++;
    setState(() {
      _reactions.add(_FloatingReaction(id: id, emoji: r.emoji));
      // Cap concurrent particles so a flood can't grow the list unbounded.
      if (_reactions.length > 40) _reactions.removeAt(0);
    });
  }

  void _removeReaction(int id) {
    if (!mounted) return;
    setState(() => _reactions.removeWhere((f) => f.id == id));
  }

  /// Send a reaction, throttled to ~5/sec so rapid taps don't flood the channel.
  Future<void> _sendReaction(String emoji) async {
    final channel = _chatChannel;
    if (channel == null) return;
    final now = DateTime.now();
    if (_lastReactionSentAt != null &&
        now.difference(_lastReactionSentAt!) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastReactionSentAt = now;
    await ChatService.sendReaction(channel, emoji: emoji);
  }

  // ── Tipping ─────────────────────────────────────────────────────────────────

  /// True when the current user can tip: a live show they don't host.
  bool get _canTip =>
      _eventStatus == 'live' &&
      !_streamEnded &&
      _eventDbId != null &&
      _hostId != null &&
      _hostId != supabase.auth.currentUser?.id;

  /// Reactions are available to everyone on a live show (host included).
  bool get _canReact => _eventStatus == 'live' && !_streamEnded;

  void _openTipSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => _TipSheet(onPick: _startTip),
    );
  }

  /// Kicks off checkout for [amountCents] and opens the hosted page externally.
  Future<void> _startTip(int amountCents) async {
    final eventId = _eventDbId;
    if (eventId == null) return;
    try {
      final url = await TipService.createCheckoutUrl(
        eventId: eventId,
        amountCents: amountCents,
      );
      _tipPending = true; // confirmed + announced on resume
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        _tipPending = false;
        _showSnack("Couldn't open checkout");
      }
    } catch (e) {
      _tipPending = false;
      final msg = e.toString().contains('host_not_payable')
          ? "This host isn't set up to receive tips yet."
          : "Couldn't start the tip";
      _showSnack(msg);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Realtime callback ─────────────────────────────────────────────────────

  void _onRealtimeUpdate(Map<String, dynamic> record) {
    if (!mounted) return;
    final wasSoundcheck = _eventStatus == 'soundcheck';
    setState(() {
      if (record['viewer_count'] != null) {
        _viewerCount = record['viewer_count'] as int;
      }
      // Status flips drive the Lobby → stream transition. When Start Show is
      // pressed, status becomes 'live' and the build switches automatically;
      // the sponsor video is disposed so audio can't bleed into the stream.
      if (record['status'] is String) {
        _eventStatus = record['status'] as String;
      }
      if (record['status'] == 'ended') {
        _streamEnded = true;
      }
    });
    if (record['status'] == 'live' || record['status'] == 'ended') {
      _teardownLobby();
    }

    // The token we joined the Lobby with carries no subscribe rights — Sound
    // Check is a rehearsal and the server withholds them until the show is
    // actually live (see LivekitService.viewerToken's `lobbySafe`). Going live
    // therefore needs a fresh token, not just a rebuild. _attemptReconnect is
    // exactly that job — poll status, re-mint, rejoin, back off on failure — so
    // reuse it rather than growing a second rejoin path that can rot separately.
    if (record['status'] == 'live' &&
        wasSoundcheck &&
        _state == ViewerState.watching &&
        !_streamEnded &&
        !_reconnecting) {
      _reconnecting = true;
      _goingLive = true;
      _reconnectAttempt = 0;
      _attemptReconnect();
    }
  }

  // ── Join ──────────────────────────────────────────────────────────────────

  Future<void> _joinAsViewer() async {
    final eventId = _eventIdController.text.trim();
    if (eventId.isEmpty) {
      setState(() => _errorMessage = 'Please enter an Event ID.');
      return;
    }

    setState(() {
      _state = ViewerState.connecting;
      _errorMessage = null;
    });

    Room? room;
    try {
      // Fetch initial event state (viewer count + guard against already-ended)
      final eventState = await EventService.fetchEventState(eventId);
      if (eventState != null) {
        // Was `status == 'ended'` only, so an abandoned Sound Check opened a
        // live viewer onto a room nobody was ever going to publish into.
        final status = eventState['status'] as String? ?? '';
        final over = Event.isOverAt(
          status: status,
          scheduledAt: _parseTs(eventState['scheduled_at']),
          endAt: _parseTs(eventState['end_at']),
        );
        if (over) {
          setState(() {
            _state = ViewerState.idle;
            _errorMessage = status == 'ended'
                ? 'This stream has already ended.'
                : 'This event didn’t take place.';
          });
          return;
        }
      }

      // Viewer identity now comes from the signed-in user's JWT (the Edge
      // Function reads it server-side) — we no longer send a viewerId.
      final conn = await LivekitService.viewerToken(eventId: eventId);

      // The descriptor's mode is "webrtc" today; an "hls" mode is reserved for
      // much higher scale and would connect differently here.
      if (conn.mode != 'webrtc') {
        throw Exception('Unsupported stream mode: ${conn.mode}');
      }
      final token = conn.token;
      final wsUrl = conn.wsUrl;

      // adaptiveStream sizes each subscription to the renderer showing it: the
      // focused feed pulls the full simulcast layer while the multicam
      // thumbnails pull a low one, and anything scrolled off screen pauses.
      // Without it every viewer pulls top quality on every feed at once, which
      // stalls cellular connections into the reconnect loop below.
      room = Room(roomOptions: const RoomOptions(adaptiveStream: true));
      final listener = room.createListener();

      listener
        ..on<TrackSubscribedEvent>(_onTrackSubscribed)
        ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
        ..on<ParticipantConnectedEvent>(_onParticipantConnected)
        ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected)
        ..on<ParticipantMetadataUpdatedEvent>(_onParticipantMetadataUpdated)
        ..on<RoomDisconnectedEvent>(_onRoomDisconnected);

      // Fail loudly instead of hanging on "Joining stream…" forever.
      await room
          .connect(wsUrl, token)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Connection timed out. Try again.'),
          );

      // Read the master-audio participant's joinedAt before touching any
      // camera — it's the zero reference every camera offset is measured against.
      _audioJoinedAt = _findAudioJoinedAt(room);

      for (final participant in room.remoteParticipants.values) {
        for (final publication in participant.videoTrackPublications) {
          // Don't gate on TrackSource — it can still be `unknown` at this point.
          // _addCamera authoritatively checks the participant's role == 'camera'.
          if (publication.subscribed && publication.track != null) {
            _addCamera(
              participant,
              publication.track as VideoTrack,
              isScreenShare: _isScreenSharePub(participant, publication),
            );
          } else {
            // Hold the video back until it aligns with the audio timeline; the
            // track arrives via TrackSubscribedEvent. Covers autoSubscribe off.
            _delayedSubscribeVideo(participant, publication);
          }
        }
        for (final publication in participant.audioTrackPublications) {
          if (publication.subscribed && publication.track != null) {
            _storeAudioPublication(participant, publication);
          } else {
            publication.subscribe();
          }
        }
      }

      // Reconcile the viewer count from LiveKit now, then on a light interval —
      // authoritative and self-healing (replaces the drift-prone increment).
      LivekitService.reconcileViewers(eventId: eventId).catchError((_) {});
      _viewerReconcileTimer?.cancel();
      _viewerReconcileTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => LivekitService.reconcileViewers(eventId: eventId).catchError((_) {}),
      );

      final eventConn = ResilientChannel(
        onResync: () => _resyncEventState(eventId),
        build: (onStatus) => EventService.subscribeToEvent(
          liveKitEventId: eventId,
          onUpdate: _onRealtimeUpdate,
          onStatus: onStatus,
        ),
      );

      // Open the ephemeral chat channel and resolve our username once for
      // outgoing messages (broadcast carries no profile join).
      final chatChannel = ChatService.subscribe(
        eventId,
        _onChatMessage,
        onReaction: _onReaction,
      );
      // Server-authored announcements (tips) arrive on their own read-only
      // topic — see ChatService.subscribeSystem.
      _systemChannel = ChatService.subscribeSystem(eventId, _onChatMessage);
      ProfileService.fetchCurrentProfile().then((p) {
        _myUsername = p?.username;
        _myAvatarUrl = p?.avatarUrl;
      }).catchError((_) => null);

      final hostProfile = eventState?['profiles'] as Map<String, dynamic>?;
      setState(() {
        _room = room;
        _listener = listener;
        _masterAudioIdentity = _findMasterAudioIdentity(room);
        _streamEventId = eventId;
        _viewerCount = eventState?['viewer_count'] as int? ?? 0;
        _eventStatus = eventState?['status'] as String?;
        _eventDbId = eventState?['id'] as String?;
        _eventTitle = eventState?['title'] as String?;
        _hostId = eventState?['host_id'] as String?;
        _scheduledAt = _parseTs(eventState?['scheduled_at']);
        _endAt = _parseTs(eventState?['end_at']);
        _coverImageUrl = eventState?['cover_image_url'] as String?;
        _hostUsername = (hostProfile?['display_name'] ??
            hostProfile?['username']) as String?;
        _hostAvatarUrl = hostProfile?['avatar_url'] as String?;
        _hasIncrementedViewerCount = true;
        _eventConn = eventConn;
        _chatChannel = chatChannel;
        _state = ViewerState.watching;
      });

      // Entering during Sound Check → set up the Pre-Show lobby (sponsor
      // creative + countdown). Live entry skips it entirely.
      if (_inLobby) _initLobby();

      _updateAudioRouting();
    } catch (e) {
      await room?.disconnect();
      if (!mounted) return;
      setState(() {
        _state = ViewerState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  // ── LiveKit event handlers ────────────────────────────────────────────────

  void _onTrackSubscribed(TrackSubscribedEvent event) {
    // Don't gate on TrackSource (can be `unknown` at subscribe time) — _addCamera
    // checks the participant's role == 'camera' authoritatively.
    if (event.track is VideoTrack) {
      final isScreen = _isScreenSharePub(event.participant, event.publication);
      final idx = _cameras.indexWhere(
        (c) =>
            c.identity == event.participant.identity &&
            c.isScreenShare == isScreen,
      );
      if (idx != -1) {
        setState(() {
          _cameras[idx] = CameraFeed(
            identity: _cameras[idx].identity,
            cameraName: _cameras[idx].cameraName,
            track: event.track as VideoTrack,
            isScreenShare: isScreen,
          );
        });
      } else {
        _addCamera(
          event.participant,
          event.track as VideoTrack,
          isScreenShare: isScreen,
        );
      }
    } else if (event.track is AudioTrack) {
      _storeAudioPublication(event.participant, event.publication);
    }
  }

  void _onTrackUnsubscribed(TrackUnsubscribedEvent event) {
    if (event.track is VideoTrack) {
      final isScreen = _isScreenSharePub(event.participant, event.publication);
      final idx = _cameras.indexWhere(
        (c) =>
            c.identity == event.participant.identity &&
            c.isScreenShare == isScreen,
      );
      if (idx != -1) {
        setState(() {
          if (isScreen) {
            // A stopped share is gone for good — drop the tile entirely
            // instead of leaving a dead placeholder.
            _cameras.removeAt(idx);
            if (_focusedIndex >= _cameras.length && _cameras.isNotEmpty) {
              _focusedIndex = _cameras.length - 1;
            }
          } else {
            // A camera can come back (video toggle) — keep the placeholder.
            _cameras[idx] = CameraFeed(
              identity: _cameras[idx].identity,
              cameraName: _cameras[idx].cameraName,
              track: null,
            );
          }
        });
      }
      _updateAudioRouting();
    } else if (event.track is AudioTrack) {
      _audioPublications.remove(event.participant.identity);
    }
  }

  void _onParticipantDisconnected(ParticipantDisconnectedEvent event) {
    _audioPublications.remove(event.participant.identity);
    setState(() {
      _cameras.removeWhere((c) => c.identity == event.participant.identity);
      if (_focusedIndex >= _cameras.length && _cameras.isNotEmpty) {
        _focusedIndex = _cameras.length - 1;
      }
    });
    if (event.participant.identity == _masterAudioIdentity) {
      final newIdentity = _findMasterAudioIdentity(_room);
      setState(() => _masterAudioIdentity = newIdentity);
    }
    _updateAudioRouting();
  }

  void _onParticipantConnected(ParticipantConnectedEvent event) {
    final newIdentity = _findMasterAudioIdentity(_room);
    if (newIdentity != _masterAudioIdentity) {
      setState(() => _masterAudioIdentity = newIdentity);
      _updateAudioRouting();
    }

    // Camera sync on (re)join: a fresh token carries a fresh server-stamped
    // joinedAt. If the master-audio participant (re)joined, refresh the zero
    // reference so every subsequent camera offset is measured against it.
    final meta = _parseMeta(event.participant.metadata);
    final role = meta['role'];
    if (role == 'master-audio' ||
        (role == 'camera' && meta['isMasterAudio'] == true)) {
      final ja = (meta['joinedAt'] as num?)?.toInt();
      if (ja != null) _audioJoinedAt = ja;
    }
    // Subscribe this participant's video held back to the audio timeline. Same
    // path as initial join — no special-casing.
    for (final publication in event.participant.videoTrackPublications) {
      if (!publication.subscribed) {
        _delayedSubscribeVideo(event.participant, publication);
      }
    }
  }

  // ── Camera sync ───────────────────────────────────────────────────────────

  Map<String, dynamic> _parseMeta(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map<String, dynamic> ? m : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// joinedAt of the master-audio source — the zero reference for offsets.
  int? _findAudioJoinedAt(Room? room) {
    if (room == null) return null;
    for (final p in room.remoteParticipants.values) {
      final meta = _parseMeta(p.metadata);
      if (meta['role'] == 'master-audio') {
        return (meta['joinedAt'] as num?)?.toInt();
      }
    }
    for (final p in room.remoteParticipants.values) {
      final meta = _parseMeta(p.metadata);
      if (meta['role'] == 'camera' && meta['isMasterAudio'] == true) {
        return (meta['joinedAt'] as num?)?.toInt();
      }
    }
    return null;
  }

  /// Subscribe a camera's video held back so it aligns with the audio timeline.
  /// A camera that joined before audio is delayed by (audioJoinedAt -
  /// cameraJoinedAt), clamped to [0, _maxSyncDelayMs]; one that joined after
  /// (or any case with missing data) subscribes immediately.
  void _delayedSubscribeVideo(
    RemoteParticipant participant,
    RemoteTrackPublication publication,
  ) {
    // Screen shares aren't part of the audio-sync dance — show immediately.
    if (publication.source == TrackSource.screenShareVideo) {
      publication.subscribe();
      return;
    }
    final cameraJoinedAt =
        (_parseMeta(participant.metadata)['joinedAt'] as num?)?.toInt();
    int delayMs = 0;
    if (_audioJoinedAt != null && cameraJoinedAt != null) {
      delayMs = (_audioJoinedAt! - cameraJoinedAt).clamp(0, _maxSyncDelayMs);
    }
    if (delayMs == 0) {
      publication.subscribe();
      return;
    }
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted || _room == null) return;
      if (!publication.subscribed) publication.subscribe();
    });
  }

  void _onParticipantMetadataUpdated(ParticipantMetadataUpdatedEvent event) {
    final newIdentity = _findMasterAudioIdentity(_room);
    if (newIdentity != _masterAudioIdentity) {
      setState(() => _masterAudioIdentity = newIdentity);
      _updateAudioRouting();
    }
  }

  void _onRoomDisconnected(RoomDisconnectedEvent event) {
    // The LiveKit room dropped. This is NOT the same as the show ending — the
    // room also closes when the last camera leaves (app backgrounded, network
    // blip, crash) while the host hasn't pressed End Stream. The DB `status`
    // column is the single source of truth for "is this show over". So instead
    // of ending here, attempt to reconnect; only `status == 'ended'` (handled
    // in _onRealtimeUpdate / the poll below) actually ends the show.
    if (!mounted ||
        _state != ViewerState.watching ||
        _streamEnded ||
        _reconnecting) {
      return;
    }
    _reconnecting = true;
    _reconnectAttempt = 0;
    _attemptReconnect();
  }

  /// Both flags always clear together; a rejoin is either in flight or it isn't.
  void _clearReconnect() {
    _reconnecting = false;
    _goingLive = false;
  }

  /// Poll the DB status and re-join the room with a fresh token. Retries with
  /// backoff while the show is still live/soundcheck; stops (and ends) only if
  /// the DB says `ended`. The realtime channel stays subscribed throughout, so
  /// a host pressing End Stream mid-reconnect flips _streamEnded immediately.
  Future<void> _attemptReconnect() async {
    final eventId = _streamEventId;
    if (!mounted || eventId == null || _streamEnded) {
      if (mounted) setState(_clearReconnect);
      return;
    }

    // The status poll has to be inside the try. It is the first call to fail
    // when the network is down — the exact condition this loop exists for — and
    // an escaping throw would leave _reconnecting stuck true for the rest of
    // the session, pinning the viewer on "Reconnecting…" and making every
    // later disconnect early-return, even after the network comes back.
    try {
      final state = await EventService.fetchEventState(eventId);
      if (!mounted) return;
      if (state?['status'] == 'ended') {
        setState(() {
          _clearReconnect();
          _streamEnded = true;
        });
        return;
      }

      await _rejoinRoom(eventId);
      if (mounted) setState(_clearReconnect);
    } catch (_) {
      _reconnectAttempt++;
      // Back off: 2s, 4s, 6s … capped at 10s. Keep trying until the host ends.
      final delay = Duration(seconds: (2 * _reconnectAttempt).clamp(2, 10));
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(delay, () {
        if (mounted && _reconnecting && !_streamEnded) _attemptReconnect();
      });
    }
  }

  /// Tear down the dead room and connect a fresh one for [eventId], re-wiring
  /// listeners and re-subscribing to existing tracks. Throws on failure so the
  /// caller can back off and retry.
  Future<void> _rejoinRoom(String eventId) async {
    await _listener?.dispose();
    await _room?.disconnect();

    final conn = await LivekitService.viewerToken(eventId: eventId);
    if (conn.mode != 'webrtc') {
      throw Exception('Unsupported stream mode: ${conn.mode}');
    }

    // Same adaptive subscription behaviour as the first join above.
    final room = Room(roomOptions: const RoomOptions(adaptiveStream: true));
    final listener = room.createListener();
    listener
      ..on<TrackSubscribedEvent>(_onTrackSubscribed)
      ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
      ..on<ParticipantConnectedEvent>(_onParticipantConnected)
      ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected)
      ..on<ParticipantMetadataUpdatedEvent>(_onParticipantMetadataUpdated)
      ..on<RoomDisconnectedEvent>(_onRoomDisconnected);

    await room
        .connect(conn.wsUrl, conn.token)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw Exception('Reconnect timed out.'),
        );

    _audioJoinedAt = _findAudioJoinedAt(room);
    setState(() {
      _cameras.clear();
      _audioPublications.clear();
      _focusedIndex = 0;
      _room = room;
      _listener = listener;
      _masterAudioIdentity = _findMasterAudioIdentity(room);
    });

    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        if (publication.subscribed && publication.track != null) {
          _addCamera(
            participant,
            publication.track as VideoTrack,
            isScreenShare: _isScreenSharePub(participant, publication),
          );
        } else {
          _delayedSubscribeVideo(participant, publication);
        }
      }
      for (final publication in participant.audioTrackPublications) {
        if (publication.subscribed && publication.track != null) {
          _storeAudioPublication(participant, publication);
        } else {
          publication.subscribe();
        }
      }
    }
    _updateAudioRouting();
  }

  // ── Audio management ──────────────────────────────────────────────────────

  void _storeAudioPublication(
    RemoteParticipant participant,
    RemoteTrackPublication publication,
  ) {
    try {
      final meta = jsonDecode(participant.metadata ?? '{}');
      final role = meta['role'] as String?;
      if (role == 'camera' || role == 'master-audio') {
        _audioPublications[participant.identity] = publication;
        _updateAudioRouting();
      }
    } catch (_) {}
  }

  String? _findMasterAudioIdentity(Room? room) {
    if (room == null) return null;
    for (final p in room.remoteParticipants.values) {
      try {
        final meta = jsonDecode(p.metadata ?? '{}');
        if (meta['role'] == 'master-audio') return p.identity;
      } catch (_) {}
    }
    for (final p in room.remoteParticipants.values) {
      try {
        final meta = jsonDecode(p.metadata ?? '{}');
        if (meta['role'] == 'camera' && meta['isMasterAudio'] == true) {
          return p.identity;
        }
      } catch (_) {}
    }
    return null;
  }

  void _updateAudioRouting() {
    if (!_audioEnabled) {
      for (final pub in _audioPublications.values) {
        pub.unsubscribe();
      }
      return;
    }
    final target =
        _masterAudioIdentity ??
        (_cameras.isNotEmpty
            ? _cameras[_focusedIndex.clamp(0, _cameras.length - 1)].identity
            : null);
    if (target == null) return;
    for (final entry in _audioPublications.entries) {
      if (entry.key == target) {
        entry.value.subscribe();
      } else {
        entry.value.unsubscribe();
      }
    }
  }

  String _masterAudioName() {
    if (_masterAudioIdentity == null) return '';
    for (final c in _cameras) {
      if (c.identity == _masterAudioIdentity) return c.cameraName;
    }
    return _room?.remoteParticipants[_masterAudioIdentity]?.name ??
        _masterAudioIdentity!;
  }

  bool _isStreamAudioSource() {
    if (_masterAudioIdentity == null || _room == null) return false;
    try {
      final meta = jsonDecode(
        _room!.remoteParticipants[_masterAudioIdentity]?.metadata ?? '{}',
      );
      return meta['role'] == 'master-audio';
    } catch (_) {
      return false;
    }
  }

  // ── Camera helpers ────────────────────────────────────────────────────────

  /// Whether a video publication is a screen share. Source is stamped at
  /// publish time; the fallback covers the brief `unknown` window by checking
  /// if this participant's camera tile is already occupied by another track.
  bool _isScreenSharePub(
    RemoteParticipant participant,
    RemoteTrackPublication publication,
  ) {
    if (publication.source == TrackSource.screenShareVideo) return true;
    if (publication.source != TrackSource.unknown) return false;
    return _cameras.any(
      (c) =>
          c.identity == participant.identity &&
          !c.isScreenShare &&
          c.track != null &&
          c.track!.sid != publication.sid,
    );
  }

  void _addCamera(
    RemoteParticipant participant,
    VideoTrack track, {
    bool isScreenShare = false,
  }) {
    Map<String, dynamic> meta;
    try {
      meta = jsonDecode(participant.metadata ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (meta['role'] != 'camera') return;
    if (_cameras.any(
      (c) =>
          c.identity == participant.identity &&
          c.isScreenShare == isScreenShare,
    )) {
      return;
    }

    final cameraName =
        (meta['cameraName'] as String?) ??
        (participant.name.isNotEmpty ? participant.name : participant.identity);

    setState(() {
      _cameras.add(
        CameraFeed(
          identity: participant.identity,
          cameraName: cameraName,
          track: track,
          isScreenShare: isScreenShare,
        ),
      );
    });
    _updateAudioRouting();
  }

  // ── Leave ─────────────────────────────────────────────────────────────────

  Future<void> _leave() async {
    _decrementAndCleanup();
    await _listener?.dispose();
    await _room?.disconnect();
    setState(() {
      _room = null;
      _listener = null;
      _cameras.clear();
      _audioPublications.clear();
      _focusedIndex = 0;
      _masterAudioIdentity = null;
      _audioEnabled = true;
      _viewerCount = 0;
      _streamEventId = null;
      _streamEnded = false;
      _eventStatus = null;
      _eventDbId = null;
      _hostId = null;
      _scheduledAt = null;
      _coverImageUrl = null;
      _hostUsername = null;
      _hostAvatarUrl = null;
      _tipPending = false;
      _chatMessages.clear();
      _chatController.clear();
      _chatOpen = false;
      _chatPinned = false;
      _hasUnreadChat = false;
      _chatAtBottom = true;
      _pendingChatCount = 0;
      _reactions.clear();
      _myUsername = null;
      _state = ViewerState.idle;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Desktop gets a body of its own rather than conditionals threaded through
    // the phone one — same split as EventDetailScreen, and for the same reason:
    // this screen shipped to beta and the phone tree has to stay exactly as it
    // is. Everything below this line is the compact layout, untouched.
    if (!NileBreakpoints.of(context).isCompact) return _buildDesktopScaffold();
    _chatPinned = false;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: _state == ViewerState.watching
          ? null // full-screen watching: no AppBar
          : AppBar(
              title: Text('Watch', style: NileTextStyles.headingMd()),
              backgroundColor: Colors.transparent,
            ),
      body: switch (_state) {
        ViewerState.idle => _buildForm(),
        ViewerState.connecting => _buildConnecting(),
        ViewerState.watching => _buildWatching(),
      },
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(NileSpacing.s32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Join a stream', style: NileTextStyles.headingLg()),
          const SizedBox(height: 32),
          TextField(
            controller: _eventIdController,
            style: NileTextStyles.bodyLg(),
            decoration: const InputDecoration(
              labelText: 'Event ID',
              hintText: 'e.g. my-live-show',
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.error),
            ),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _joinAsViewer,
            icon: const Icon(Icons.tv),
            label: const Text('Watch Now'),
            style: FilledButton.styleFrom(
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.onVolt,
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              textStyle: NileTextStyles.labelLg(),
              shape: const StadiumBorder(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnecting() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: NileColors.volt),
          const SizedBox(height: 16),
          Text('Joining stream...', style: NileTextStyles.bodyMd()),
        ],
      ),
    );
  }

  // ── Lobby (host in Sound Check) ───────────────────────────────────────────

  /// The Pre-Show lobby (0079): a full-bleed sponsor creative (or the event
  /// cover when unsponsored) under a countdown + event/host overlay, with live
  /// chat available before the show. The realtime flip to 'live' tears this
  /// down and drops everyone into the stream.
  Widget _buildLobby() {
    return Stack(
      children: [
        Positioned.fill(child: _buildLobbyBackground()),
        Positioned.fill(child: _buildLobbyScrim()),
        Column(
          children: [
            _buildTopBar(),
            const Spacer(),
            // Event + countdown overlay (kept clear of the chat overlay's edge).
            SafeArea(
              top: false,
              child: NileMaxWidth(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      NileSpacing.s16, 0, NileSpacing.s16, NileSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: _lobbyBlocks(),
                  ),
                ),
              ),
            ),
          ],
        ),
        // Live chat is open for business before the show (plan decision:
        // chat pre-show yes; tips + reactions stay live-only).
        if (!_streamEnded) _buildChatOverlay(),
      ],
    );
  }

  /// The lobby's full-bleed creative, in priority order: sponsor video →
  /// sponsor image → the video's thumb while it buffers → the event cover →
  /// a plain surface. Tapping a sponsored lobby opens the sponsor's link (and
  /// logs the click).
  ///
  /// Extracted so the desktop lobby can use the same creative behind its hero.
  /// The sponsor impression logged in [_initLobby] assumes the creative is the
  /// whole screen, which is why the desktop layout keeps it full-bleed behind
  /// the countdown rather than shrinking it into a card.
  Widget _buildLobbyBackground() {
    final spons = _sponsorship;
    final controller = _sponsorController;
    final videoReady = controller != null && controller.value.isInitialized;
    final bgImageUrl = spons == null
        ? _coverImageUrl
        : (spons.kind == 'image' ? spons.imageUrl : (spons.thumbUrl ?? _coverImageUrl));

    return GestureDetector(
      onTap: spons != null ? _openSponsorLink : null,
      child: videoReady
          ? FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            )
          : bgImageUrl != null
              ? Image.network(
                  bgImageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: NileColors.bgSurface),
                )
              : ColoredBox(color: NileColors.bgSurface),
    );
  }

  /// Scrims so the top bar and overlay text stay readable on any creative.
  Widget _buildLobbyScrim() {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.55),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.75),
            ],
            stops: const [0, 0.25, 0.55, 1],
          ),
        ),
      ),
    );
  }

  /// Countdown, title and host — the lobby's text, in the order it reads.
  ///
  /// [large] is the desktop hero treatment: same blocks, two steps up in type
  /// and a host avatar that survives being looked at from a metre away. The
  /// default is the phone measure, so compact renders exactly what it did.
  List<Widget> _lobbyBlocks({bool large = false}) {
    final spons = _sponsorship;
    final controller = _sponsorController;
    final videoReady = controller != null && controller.value.isInitialized;
    final avatarRadius = large ? 18.0 : 12.0;

    return [
      // Persistent sponsorship disclosure.
      if (spons != null) ...[
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(NileRadius.xs),
          ),
          child: Text(
            'Sponsored · ${spons.advertiserName}',
            style: NileTextStyles.caption().copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: NileSpacing.s8),
      ],
      Text(
        _countdownLabel,
        style: (large ? NileTextStyles.displayMd() : NileTextStyles.headingLg())
            .copyWith(color: Colors.white),
      ),
      if (_eventTitle != null) ...[
        const SizedBox(height: NileSpacing.s4),
        Text(
          _eventTitle!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (large ? NileTextStyles.headingMd() : NileTextStyles.bodyLg())
              .copyWith(color: Colors.white),
        ),
      ],
      if (_hostUsername != null) ...[
        const SizedBox(height: NileSpacing.s8),
        Row(
          children: [
            CircleAvatar(
              radius: avatarRadius,
              backgroundColor: NileColors.bgSurface,
              backgroundImage: _hostAvatarUrl != null
                  ? NetworkImage(_hostAvatarUrl!)
                  : null,
              child: _hostAvatarUrl == null
                  ? Icon(Icons.person,
                      size: avatarRadius + 2, color: Colors.white70)
                  : null,
            ),
            const SizedBox(width: NileSpacing.s8),
            Expanded(
              child: Text(
                _hostUsername!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    (large ? NileTextStyles.bodyLg() : NileTextStyles.bodySm())
                        .copyWith(
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ),
            // Tap-to-unmute for video creatives.
            if (videoReady)
              IconButton(
                icon: Icon(
                  _sponsorMuted ? Icons.volume_off : Icons.volume_up,
                ),
                color: Colors.white,
                iconSize: 20,
                tooltip: _sponsorMuted ? 'Unmute' : 'Mute',
                onPressed: _toggleSponsorMute,
              ),
          ],
        ),
      ],
    ];
  }

  Widget _buildCameraOffPlaceholder({required bool large}) {
    return Container(
      color: NileColors.bgSurface,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videocam_off,
              size: large ? 48 : 24,
              color: NileColors.border,
            ),
            if (large) ...[
              const SizedBox(height: 8),
              Text(
                'Camera Off',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Connected, but no camera has published yet. Shared by both bodies so the
  /// wait reads the same whichever one you are looking at.
  Widget _buildWaitingForCameras() {
    // Only a live show is actually waiting for cameras. A 'scheduled' row used
    // to fall through to here and spin this spinner forever — the reconnect
    // loop only stops on 'ended', so nothing ever took it off screen.
    if (_eventStatus != 'live' && !_streamEnded) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.videocam_off_outlined,
                size: 40,
                color: NileColors.txtTertiary,
              ),
              const SizedBox(height: 16),
              Text(
                _isOver
                    ? 'This event didn’t take place'
                    : 'This show hasn’t started yet',
                textAlign: TextAlign.center,
                style: NileTextStyles.headingSm(),
              ),
              const SizedBox(height: 8),
              Text(
                _isOver
                    ? 'The host never went live.'
                    : 'Check the event page for the start time.',
                textAlign: TextAlign.center,
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: NileColors.volt),
          const SizedBox(height: 16),
          Text(
            'Waiting for cameras to connect...',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWatching() {
    // Lobby: the host is in Sound Check — hold viewers here until Start Show
    // flips status to 'live' (handled by realtime in _onRealtimeUpdate).
    if (_inLobby) {
      return _buildLobby();
    }
    return Stack(
      children: [
        Column(
          children: [
            _buildTopBar(),
            if (_cameras.isEmpty)
              Expanded(child: _buildWaitingForCameras())
            else
              Expanded(
                child: OrientationBuilder(
                  builder: (context, orientation) {
                    final isLandscape = orientation == Orientation.landscape;
                    return Column(
                      children: [
                        _buildAudioBar(),
                        Expanded(
                          child: isLandscape
                              ? _buildLandscapeLayout()
                              : _buildPortraitLayout(),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),

        // Floating emoji reactions — non-interactive layer over the video.
        if (!_streamEnded) _buildReactionOverlay(),

        // Tap-to-react rail (live only, hidden while the chat panel is open).
        if (_canReact && !_chatOpen) _buildReactionRail(),

        // Collapsible live chat — sits above the video, slides off when closed
        if (!_streamEnded) _buildChatOverlay(),

        // Reconnecting overlay — room dropped but the show is still live.
        if (_reconnecting && !_streamEnded) _buildReconnectingOverlay(),

        // Stream ended overlay
        if (_streamEnded) _buildStreamEndedOverlay(),
      ],
    );
  }

  Widget _buildReconnectingOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: NileColors.bgPage.withValues(alpha: 0.85),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: NileColors.volt),
              const SizedBox(height: 16),
              Text(
                _goingLive ? 'Starting…' : 'Reconnecting…',
                style: NileTextStyles.headingMd(),
              ),
              const SizedBox(height: 8),
              Text(
                _goingLive
                    ? 'The show is beginning.'
                    : 'The stream dropped briefly. Hang tight.',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Top bar (viewer count + leave) ────────────────────────────────────────

  /// [showChatToggle] is false on desktop, where chat is a column that is
  /// always up — a button that opens what is already open is a button that
  /// does nothing.
  Widget _buildTopBar({bool showChatToggle = true}) {
    // In the Lobby the bar floats over the full-bleed creative (the scrim
    // keeps it readable); everywhere else it keeps its solid background.
    final inLobbyBar = _inLobby;
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 8,
        bottom: 8,
      ),
      color: inLobbyBar ? Colors.transparent : NileColors.bgPage,
      child: Row(
        children: [
          // Status badge — SOUND CHECK (volt) in the Lobby, LIVE (coral) once live
          Builder(
            builder: (_) {
              final inLobby = _inLobby;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
                decoration: BoxDecoration(
                  color: inLobby ? NileColors.volt : NileColors.coral,
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: Text(
                  inLobby ? 'SOUND CHECK' : 'LIVE',
                  style: NileTextStyles.caption().copyWith(
                    color: inLobby ? NileColors.onVolt : Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          // Viewer count
          Icon(Icons.visibility, size: 14, color: NileColors.txtTertiary),
          const SizedBox(width: 4),
          NileRollingNumber(
            value: _viewerCount,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const Spacer(),
          // Tip button — live shows only, never for the host's own show.
          if (_canTip)
            IconButton(
              icon: const Icon(Icons.volunteer_activism),
              color: NileColors.volt,
              iconSize: 20,
              tooltip: 'Send a tip',
              onPressed: _openTipSheet,
            ),
          // Share — canonical event link, available any time while watching.
          if (_eventDbId != null)
            IconButton(
              icon: const Icon(Icons.ios_share),
              color: NileColors.txtSecondary,
              iconSize: 20,
              tooltip: 'Share',
              onPressed: _shareStream,
            ),
          // Chat toggle — available in the Lobby too (pre-show chat, 0079)
          if (!_streamEnded && showChatToggle)
            Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: Icon(
                    _chatOpen ? Icons.chat_bubble : Icons.chat_bubble_outline,
                  ),
                  color: _chatOpen ? NileColors.volt : NileColors.txtSecondary,
                  iconSize: 20,
                  onPressed: _toggleChat,
                ),
                if (_hasUnreadChat && !_chatOpen)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: CircleAvatar(
                      radius: 4,
                      backgroundColor: NileColors.coral,
                    ),
                  ),
              ],
            ),
          // Leave button
          TextButton(
            onPressed: _leave,
            child: Text(
              'Leave',
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.error),
            ),
          ),
        ],
      ),
    );
  }

  // ── Reactions ─────────────────────────────────────────────────────────────

  Widget _buildReactionOverlay() {
    // Particles rise from the lower-right and fade; the layer never blocks taps.
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            for (final r in _reactions)
              _FloatingReactionWidget(
                key: ValueKey(r.id),
                emoji: r.emoji,
                onDone: () => _removeReaction(r.id),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReactionRail() {
    return Positioned(
      right: NileSpacing.s8,
      bottom: 96,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final emoji in _reactionEmojis)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s4),
              child: Material(
                color: NileColors.bgPage.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _sendReaction(emoji),
                  child: Padding(
                    padding: const EdgeInsets.all(NileSpacing.s8),
                    child: Text(emoji, style: const TextStyle(fontSize: 22)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Chat overlay ──────────────────────────────────────────────────────────

  Widget _buildChatOverlay() {
    final media = MediaQuery.of(context);
    // Panel covers the lower ~42% of the screen; slides fully off-screen when
    // collapsed so it never blocks the video.
    final panelHeight = media.size.height * 0.42;
    // On desktop/web (width > 600) pin the panel to the right at 25% width.
    final isWide = kIsWeb || media.size.width > 600;
    final panelWidth = isWide ? media.size.width * 0.25 : null;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: isWide ? null : 0,
      right: 0,
      bottom: _chatOpen ? 0 : -panelHeight,
      height: panelHeight,
      width: panelWidth,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              NileColors.bgPage.withValues(alpha: 0.0),
              NileColors.bgPage.withValues(alpha: 0.75),
              NileColors.bgPage.withValues(alpha: 0.92),
            ],
            stops: const [0.0, 0.35, 1.0],
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _buildChatList(),
                  if (_pendingChatCount > 0)
                    Positioned(
                      bottom: NileSpacing.s8,
                      left: 0,
                      right: 0,
                      child: Center(child: _buildNewMessagesPill()),
                    ),
                ],
              ),
            ),
            _buildChatInput(media.padding.bottom),
          ],
        ),
      ),
    );
  }

  Widget _buildNewMessagesPill() {
    return Material(
      color: NileColors.volt,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _jumpChatToBottom,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 14, color: NileColors.onVolt),
              const SizedBox(width: 4),
              Text(
                _pendingChatCount == 1
                    ? 'New message'
                    : '$_pendingChatCount new messages',
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.onVolt,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatList() {
    if (_chatMessages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet. Say hi 👋',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s8, NileSpacing.s16, NileSpacing.s8),
      itemCount: _chatMessages.length,
      itemBuilder: (context, i) {
        final m = _chatMessages[i];
        final row = _buildChatRow(m);
        // Gentle entry animation for the newest message only.
        if (i == _chatMessages.length - 1) {
          return TweenAnimationBuilder<double>(
            key: ValueKey('anim_${m.senderId}_${m.sentAt.microsecondsSinceEpoch}'),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: child),
            ),
            child: row,
          );
        }
        return row;
      },
    );
  }

  Widget _buildChatRow(ChatMessage m) {
    if (m.isSystem) {
      // Tip / announcement: author-less, volt-accented pill.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s4),
        child: Row(
          children: [
            Icon(Icons.volunteer_activism, size: 14, color: NileColors.volt),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                m.content,
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.volt,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isHost = _hostId != null && m.senderId == _hostId;
    final nameColor = isHost
        ? NileColors.coral
        : (m.isMine ? NileColors.volt : NileColors.azure);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: NileSpacing.s2),
      padding: isHost
          ? const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s6)
          : EdgeInsets.zero,
      decoration: isHost
          ? BoxDecoration(
              color: NileColors.coral.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(NileRadius.sm),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chatAvatar(m),
          const SizedBox(width: NileSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        m.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.bodySm().copyWith(
                          color: nameColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (isHost) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4, vertical: 1),
                        decoration: BoxDecoration(
                          color: NileColors.coral,
                          borderRadius: BorderRadius.circular(NileRadius.xs),
                        ),
                        child: Text(
                          'HOST',
                          style: NileTextStyles.caption().copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(m.content, style: NileTextStyles.bodyMd()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatAvatar(ChatMessage m) {
    const r = 12.0;
    final url = m.avatarUrl;
    if (url != null && url.isNotEmpty) {
      return CircleAvatar(radius: r, backgroundImage: nileAvatarImage(url, r));
    }
    final initial = m.username.isNotEmpty ? m.username[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: r,
      backgroundColor: NileColors.bgRaised,
      child: Text(
        initial,
        style: NileTextStyles.caption().copyWith(color: NileColors.txtSecondary),
      ),
    );
  }

  Widget _buildChatInput(double bottomInset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(NileSpacing.s12, NileSpacing.s8, NileSpacing.s12, NileSpacing.s8 + bottomInset),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatController,
              style: NileTextStyles.bodyMd(),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendChat(),
              maxLength: 250,
              buildCounter:
                  (
                    _, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Chat…',
                fillColor: NileColors.bgRaised,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s12,
                  vertical: NileSpacing.s8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            color: NileColors.volt,
            onPressed: _sendChat,
          ),
        ],
      ),
    );
  }

  // ── Audio bar ─────────────────────────────────────────────────────────────

  Widget _buildAudioBar() {
    final hasAudio = _masterAudioIdentity != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s8),
      color: NileColors.bgSurface,
      child: Row(
        children: [
          Icon(
            _isStreamAudioSource() ? Icons.tune : Icons.album,
            size: 16,
            color: hasAudio ? NileColors.volt : NileColors.txtTertiary,
          ),
          const SizedBox(width: 6),
          Text(
            _masterAudioIdentity == null
                ? 'No master audio'
                : _isStreamAudioSource()
                ? 'Stream Audio'
                : 'Master: ${_masterAudioName()}',
            style: NileTextStyles.bodySm().copyWith(
              color: hasAudio ? NileColors.volt : NileColors.txtTertiary,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(_audioEnabled ? Icons.volume_up : Icons.volume_off),
            color: _audioEnabled
                ? NileColors.txtPrimary
                : NileColors.txtTertiary,
            iconSize: 20,
            onPressed: () {
              setState(() => _audioEnabled = !_audioEnabled);
              _updateAudioRouting();
            },
          ),
        ],
      ),
    );
  }

  // ── Layouts ───────────────────────────────────────────────────────────────

  /// Desktop gets bigger angle previews by default, plus a drag handle
  /// between the main feed and the rail so the user can resize them.
  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  double _thumbScale = _isDesktop ? 1.6 : 1.0;

  void _resizeThumbnails(double deltaPx, double basePx) {
    setState(() {
      _thumbScale = (_thumbScale + deltaPx / basePx).clamp(1.0, 3.0);
    });
  }

  /// Thin grab bar for resizing the thumbnail rail (desktop only).
  Widget _buildThumbResizeHandle({required bool horizontal}) {
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Rail sits below/right of the main feed, so dragging toward the
        // feed (negative delta) grows it.
        onVerticalDragUpdate: horizontal
            ? (d) => _resizeThumbnails(-d.delta.dy, 100)
            : null,
        onHorizontalDragUpdate: horizontal
            ? null
            : (d) => _resizeThumbnails(-d.delta.dx, 110),
        child: Container(
          height: horizontal ? 8 : null,
          width: horizontal ? null : 8,
          color: NileColors.bgPage,
          alignment: Alignment.center,
          child: Container(
            height: horizontal ? 3 : 28,
            width: horizontal ? 28 : 3,
            decoration: BoxDecoration(
              color: NileColors.txtTertiary,
              borderRadius: BorderRadius.circular(NileRadius.pill),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        Expanded(child: _buildMainCamera()),
        if (_cameras.length > 1 && _isDesktop)
          _buildThumbResizeHandle(horizontal: true),
        if (_cameras.length > 1) _buildHorizontalThumbnails(),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
      children: [
        Expanded(child: _buildMainCamera()),
        if (_cameras.length > 1 && _isDesktop)
          _buildThumbResizeHandle(horizontal: false),
        if (_cameras.length > 1) _buildVerticalThumbnails(),
      ],
    );
  }

  Widget _buildMainCamera() {
    final focused = _cameras[_focusedIndex.clamp(0, _cameras.length - 1)];
    return Stack(
      fit: StackFit.expand,
      children: [
        focused.track != null
            ? VideoTrackRenderer(focused.track!)
            : _buildCameraOffPlaceholder(large: true),
        if (focused.identity == _masterAudioIdentity)
          Positioned(
            top: 12,
            right: 12,
            child: Icon(Icons.album, color: NileColors.volt, size: 18),
          ),
        Positioned(
          bottom: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
            decoration: BoxDecoration(
              color: NileColors.bgPage.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
            child: Text(focused.displayName, style: NileTextStyles.bodyMd()),
          ),
        ),
      ],
    );
  }

  Widget _buildHorizontalThumbnails() {
    return Container(
      height: 100 * _thumbScale,
      color: NileColors.bgPage,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(NileSpacing.s8),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _buildThumbnailItem(
          index: index,
          width: 140 * _thumbScale,
          height: double.infinity,
          margin: const EdgeInsets.only(right: NileSpacing.s8),
        ),
      ),
    );
  }

  Widget _buildVerticalThumbnails() {
    return Container(
      width: 110 * _thumbScale,
      color: NileColors.bgPage,
      child: ListView.builder(
        scrollDirection: Axis.vertical,
        padding: const EdgeInsets.all(NileSpacing.s6),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _buildThumbnailItem(
          index: index,
          width: double.infinity,
          height: 80 * _thumbScale,
          margin: const EdgeInsets.only(bottom: NileSpacing.s8),
        ),
      ),
    );
  }

  Widget _buildThumbnailItem({
    required int index,
    required double width,
    required double height,
    required EdgeInsets margin,
  }) {
    final camera = _cameras[index];
    final isFocused = index == _focusedIndex;
    final isMasterAudio = camera.identity == _masterAudioIdentity;

    return GestureDetector(
      onTap: () {
        setState(() => _focusedIndex = index);
        _updateAudioRouting();
      },
      child: Container(
        width: width,
        height: height,
        margin: margin,
        decoration: BoxDecoration(
          border: Border.all(
            color: isFocused ? NileColors.volt : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(NileRadius.sm - 2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              camera.track != null
                  ? VideoTrackRenderer(camera.track!)
                  : _buildCameraOffPlaceholder(large: false),
              if (isMasterAudio)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(Icons.album, color: NileColors.volt, size: 14),
                ),
              Positioned(
                bottom: 4,
                left: 4,
                right: 4,
                child: Text(
                  camera.displayName,
                  style: NileTextStyles.caption().copyWith(
                    color: NileColors.txtPrimary,
                    shadows: const [Shadow(blurRadius: 4)],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Desktop ───────────────────────────────────────────────────────────────
  //
  // One route, three states: the countdown before the show, the show itself,
  // and what is left of it afterwards. The chrome — nav rail, top bar, back —
  // is already drawn above this route and hands it the full width left of the
  // rail (NileAppShell.wantsFullWidth), so nothing below draws navigation of
  // its own. It only decides what to do with ~1470 pt.

  /// Chat, beside the video instead of over it. Wide enough for a name and a
  /// line of text without every message wrapping twice.
  static const double _chatColumnWidth = 340;

  /// Narrower than this and the video becomes the thing being squeezed, which
  /// is the one outcome this layout exists to prevent.
  static const double _minVideoWidth = 560;

  /// Below this, the phone body is the better use of the space: chat over the
  /// video beats two columns that are both too small. Measured rather than
  /// derived from the window class — a nav rail starts at the iPad mini, and
  /// that window has nothing like the width for a second column.
  static const double _chatSplitsAt = _minVideoWidth + 1 + _chatColumnWidth;

  /// Square, and large enough to read as artwork rather than a favicon.
  static const double _lobbyCoverSize = 220;

  Widget _buildDesktopScaffold() {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      // No AppBar — the chrome's top bar is directly above this, and two
      // stacked title bars is one too many.
      body: switch (_state) {
        ViewerState.idle => NileMaxWidth(child: _buildForm()),
        ViewerState.connecting => _buildConnecting(),
        ViewerState.watching => LayoutBuilder(
          builder: (context, constraints) {
            final split = constraints.maxWidth >= _chatSplitsAt;
            // Recorded here because this is the only place that knows whether
            // the chat list ended up on screen; _onChatMessage reads it to
            // decide whether to auto-follow or raise the unread dot.
            _chatPinned = split;
            return split ? _buildDesktopWatching() : _buildWatching();
          },
        ),
      },
    );
  }

  /// The three states, each with a chat column pinned beside it.
  Widget _buildDesktopWatching() {
    final Widget main;
    if (_streamEnded) {
      main = _buildDesktopEnded();
    } else if (_inLobby) {
      main = _buildDesktopLobby();
    } else {
      main = _buildDesktopLive();
    }
    // The chrome's top bar already sits above this, so the status-bar inset has
    // been dealt with — but nothing has *removed* it from the MediaQuery, and
    // _buildTopBar adds padding.top to itself. Dropping it here stops the
    // status bar being paid for twice on an iPad; on a Mac it is zero either
    // way. SafeArea still handles the bottom and the sides.
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: main),
            const VerticalDivider(width: 1),
            SizedBox(
              width: _chatColumnWidth,
              child: _streamEnded
                  ? _buildEndedChatColumn()
                  : _buildChatColumn(),
            ),
          ],
        ),
      ),
    );
  }

  /// A — before the show.
  ///
  /// The creative stays full-bleed: the impression logged in [_initLobby]
  /// assumes it is the whole screen, so shrinking it into a card would quietly
  /// change what we told the advertiser they bought. What changes is the text
  /// at its foot, which becomes a hero — countdown two type steps up, title,
  /// host. The event's own cover art joins it only when the background is a
  /// sponsor's creative; when the background *is* the cover, a second copy of
  /// it is noise.
  ///
  /// There is no ticket gate here to lay out. Access to a stream is decided
  /// server-side by the viewer token, and the buy/you're-in UI lives on the
  /// event page — by the time you are on this route you are already in.
  Widget _buildDesktopLobby() {
    final showCoverArt = _sponsorship != null && _coverImageUrl != null;
    return Stack(
      children: [
        Positioned.fill(child: _buildLobbyBackground()),
        Positioned.fill(child: _buildLobbyScrim()),
        Column(
          children: [
            _buildTopBar(showChatToggle: false),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s40,
                0,
                NileSpacing.s40,
                NileSpacing.s40,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (showCoverArt) ...[
                    SizedBox(
                      width: _lobbyCoverSize,
                      height: _lobbyCoverSize,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(NileRadius.lg),
                        child: Image.network(
                          _coverImageUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: nileDecodeWidth(_lobbyCoverSize),
                          errorBuilder: (_, _, _) =>
                              ColoredBox(color: NileColors.bgSurface),
                        ),
                      ),
                    ),
                    const SizedBox(width: NileSpacing.s32),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: _lobbyBlocks(large: true),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// B — the show.
  ///
  /// The video fills the main area. The angle strip runs along its bottom edge
  /// rather than its side: the right edge belongs to chat now, and a contained
  /// 16:9 frame in an area this wide has its slack top and bottom anyway — the
  /// strip lands in space the video was never going to use, so putting it there
  /// costs the picture nothing. Reactions and the tip button stay where they
  /// are, over the video and in the status bar respectively.
  Widget _buildDesktopLive() {
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              _buildTopBar(showChatToggle: false),
              if (_cameras.isEmpty)
                Expanded(child: _buildWaitingForCameras())
              else ...[
                _buildAudioBar(),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(child: _buildMainCamera()),
                            // Bursts and the react rail sit over the video
                            // only, so they never drift across chat.
                            _buildReactionOverlay(),
                            if (_canReact) _buildReactionRail(),
                          ],
                        ),
                      ),
                      if (_cameras.length > 1 && _isDesktop)
                        _buildThumbResizeHandle(horizontal: true),
                      if (_cameras.length > 1) _buildHorizontalThumbnails(),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_reconnecting) _buildReconnectingOverlay(),
      ],
    );
  }

  /// C — after the show.
  ///
  /// This screen has no replay pipeline and no "up next" of its own, and it is
  /// not the place to grow one: a published replay, its price, the calendar
  /// link and the host's next date all already exist on the event page. So the
  /// end of a stream keeps the show's identity — cover, title, host — and hands
  /// off there, rather than ending on a black rectangle.
  Widget _buildDesktopEnded() {
    return Stack(
      children: [
        if (_coverImageUrl != null)
          Positioned.fill(
            child: Image.network(
              _coverImageUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(color: NileColors.bgPage),
            ),
          ),
        // The cover is atmosphere at this point, not content.
        Positioned.fill(
          child: ColoredBox(
            color: NileColors.bgPage.withValues(alpha: 0.92),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(NileSpacing.s32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.stop_circle_outlined,
                    size: 72,
                    color: NileColors.txtTertiary,
                  ),
                  const SizedBox(height: NileSpacing.s24),
                  Text('Stream ended', style: NileTextStyles.headingLg()),
                  if (_eventTitle != null) ...[
                    const SizedBox(height: NileSpacing.s8),
                    Text(
                      _eventTitle!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.bodyLg(),
                    ),
                  ],
                  if (_hostUsername != null) ...[
                    const SizedBox(height: NileSpacing.s12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: NileColors.bgRaised,
                          backgroundImage: _hostAvatarUrl != null
                              ? nileAvatarImage(_hostAvatarUrl!, 12)
                              : null,
                          child: _hostAvatarUrl == null
                              ? Icon(
                                  Icons.person,
                                  size: 14,
                                  color: NileColors.txtSecondary,
                                )
                              : null,
                        ),
                        const SizedBox(width: NileSpacing.s8),
                        Text(_hostUsername!, style: NileTextStyles.bodySm()),
                      ],
                    ),
                  ],
                  const SizedBox(height: NileSpacing.s32),
                  if (_eventDbId != null)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _openEventPage,
                        icon: const Icon(Icons.event_outlined),
                        label: const Text('Go to the event page'),
                        style: FilledButton.styleFrom(
                          backgroundColor: NileColors.volt,
                          foregroundColor: NileColors.onVolt,
                          padding: const EdgeInsets.symmetric(
                            vertical: NileSpacing.s16,
                          ),
                          textStyle: NileTextStyles.labelLg(),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  const SizedBox(height: NileSpacing.s12),
                  Text(
                    'A replay shows up there if the host publishes one, along '
                    'with their next date.',
                    textAlign: TextAlign.center,
                    style: NileTextStyles.caption(),
                  ),
                  const SizedBox(height: NileSpacing.s16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_eventDbId != null)
                        TextButton.icon(
                          onPressed: _shareStream,
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: const Text('Share'),
                        ),
                      TextButton(
                        onPressed: _leave,
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Replaces this route rather than pushing over it, so the viewer tears down
  /// — the realtime channels, the chat channel and the reconcile timer go with
  /// it — instead of staying connected to a show that is over behind a page
  /// about that same show.
  void _openEventPage() {
    final id = _eventDbId;
    if (id == null) return;
    context.go(NileRoutes.event(id));
  }

  /// Chat as a column beside the video instead of a panel over it.
  ///
  /// On a phone chat floats over the picture because there is nowhere else for
  /// it to go; here there is, and covering the show to read it is exactly what
  /// this layout exists to stop. Same list, same input, same controllers — only
  /// the frame differs, so a message takes one path on both platforms.
  Widget _buildChatColumn() {
    return ColoredBox(
      color: NileColors.bgPage,
      child: Column(
        children: [
          NileSectionHeader(
            'Live chat',
            dense: true,
            accent: _inLobby
                ? NileColors.volt
                : NileColors.coral,
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s16,
              NileSpacing.s16,
              NileSpacing.s16,
              NileSpacing.s12,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                _buildChatList(),
                if (_pendingChatCount > 0)
                  Positioned(
                    bottom: NileSpacing.s8,
                    left: 0,
                    right: 0,
                    child: Center(child: _buildNewMessagesPill()),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // The SafeArea above already ate the bottom inset.
          _buildChatInput(0),
        ],
      ),
    );
  }

  /// C — the chat that was.
  ///
  /// There is nothing to re-sync. Live chat is a Supabase *broadcast* channel
  /// with no table behind it (see ChatService): no history, no fetch, no
  /// timestamps to reconcile against a recording. What can honestly be shown is
  /// the buffer this client accumulated while it was connected — so that is
  /// what this shows, labelled as exactly that, rather than a "comments" list
  /// implying a record that does not exist.
  Widget _buildEndedChatColumn() {
    return ColoredBox(
      color: NileColors.bgPage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NileSectionHeader(
            'Chat from this session',
            dense: true,
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s16,
              NileSpacing.s16,
              NileSpacing.s16,
              NileSpacing.s4,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s16,
              0,
              NileSpacing.s16,
              NileSpacing.s12,
            ),
            child: Text(
              'Chat is broadcast live and never stored, so this is only what '
              'arrived while you were watching.',
              style: NileTextStyles.caption(),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _chatMessages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(NileSpacing.s24),
                      child: Text(
                        'Nothing was said while you were here.',
                        textAlign: TextAlign.center,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    // Deliberately not _chatScrollController: that one belongs
                    // to the live list, and two views can't share one.
                    padding: const EdgeInsets.fromLTRB(
                      NileSpacing.s16,
                      NileSpacing.s8,
                      NileSpacing.s16,
                      NileSpacing.s16,
                    ),
                    itemCount: _chatMessages.length,
                    itemBuilder: (context, i) {
                      final m = _chatMessages[i];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              top: NileSpacing.s4,
                              right: NileSpacing.s8,
                            ),
                            child: SizedBox(
                              width: 52,
                              child: Text(
                                nileClock(m.sentAt.toLocal()),
                                style: NileTextStyles.caption().tabular,
                              ),
                            ),
                          ),
                          Expanded(child: _buildChatRow(m)),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Stream ended overlay ──────────────────────────────────────────────────

  Widget _buildStreamEndedOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.stop_circle_outlined,
              size: 72,
              color: NileColors.txtTertiary,
            ),
            const SizedBox(height: 20),
            Text('Stream Ended', style: NileTextStyles.headingLg()),
            const SizedBox(height: 8),
            Text(
              'The host has ended the stream.',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            const SizedBox(height: 36),
            FilledButton(
              onPressed: _leave,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s40,
                  vertical: NileSpacing.s16,
                ),
                textStyle: NileTextStyles.labelLg(),
                shape: const StadiumBorder(),
              ),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tip amount picker: preset chips + a custom amount, dollars.
class _TipSheet extends StatefulWidget {
  final void Function(int amountCents) onPick;
  const _TipSheet({required this.onPick});

  @override
  State<_TipSheet> createState() => _TipSheetState();
}

class _TipSheetState extends State<_TipSheet> {
  final _customController = TextEditingController();
  int? _selected; // selected preset (cents); null when using custom

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _confirm() {
    int? cents = _selected;
    if (cents == null) {
      final dollars = double.tryParse(_customController.text.trim());
      if (dollars != null) cents = (dollars * 100).round();
    }
    if (cents == null ||
        cents < TipService.minCents ||
        cents > TipService.maxCents) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an amount between \$1 and \$500')),
      );
      return;
    }
    Navigator.pop(context);
    widget.onPick(cents);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Send a tip', style: NileTextStyles.headingSm()),
          const SizedBox(height: NileSpacing.s4),
          Text(
            'Support the host. Goes straight to them, minus a small platform fee.',
            style: NileTextStyles.bodySm().copyWith(color: NileColors.txtSecondary),
          ),
          const SizedBox(height: NileSpacing.s16),
          Wrap(
            spacing: NileSpacing.s8,
            runSpacing: NileSpacing.s8,
            children: [
              for (final cents in TipService.presetsCents)
                ChoiceChip(
                  label: Text('\$${cents ~/ 100}'),
                  selected: _selected == cents,
                  onSelected: (_) => setState(() {
                    _selected = cents;
                    _customController.clear();
                  }),
                  selectedColor: NileColors.volt,
                  labelStyle: NileTextStyles.labelLg().copyWith(
                    color: _selected == cents
                        ? NileColors.onVolt
                        : NileColors.txtPrimary,
                  ),
                  backgroundColor: NileColors.bgRaised,
                ),
            ],
          ),
          const SizedBox(height: NileSpacing.s16),
          TextField(
            controller: _customController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: NileTextStyles.bodyMd(),
            onChanged: (v) {
              if (v.isNotEmpty && _selected != null) {
                setState(() => _selected = null);
              }
            },
            decoration: InputDecoration(
              prefixText: '\$ ',
              hintText: 'Custom amount',
              fillColor: NileColors.bgRaised,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NileRadius.sm),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _confirm,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
                padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                textStyle: NileTextStyles.labelLg(),
                shape: const StadiumBorder(),
              ),
              child: const Text('Continue to checkout'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A live emoji reaction in flight — one floating particle.
class _FloatingReaction {
  final int id;
  final String emoji;
  const _FloatingReaction({required this.id, required this.emoji});
}

/// Renders one reaction rising from the lower-right, drifting and fading, then
/// calls [onDone] so the parent can drop it from its list.
class _FloatingReactionWidget extends StatefulWidget {
  final String emoji;
  final VoidCallback onDone;
  const _FloatingReactionWidget({
    super.key,
    required this.emoji,
    required this.onDone,
  });

  @override
  State<_FloatingReactionWidget> createState() =>
      _FloatingReactionWidgetState();
}

class _FloatingReactionWidgetState extends State<_FloatingReactionWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final double _drift; // horizontal wander
  late final double _startRight;

  @override
  void initState() {
    super.initState();
    final rnd = Random();
    _drift = (rnd.nextDouble() - 0.5) * 70;
    _startRight = 16 + rnd.nextDouble() * 44;
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        // Fade in quickly, then out over the rest of the rise.
        final opacity = (t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85)
            .clamp(0.0, 1.0);
        return Positioned(
          right: _startRight + _drift * t,
          bottom: 110 + 230 * t,
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: 0.8 + 0.4 * t,
              child: Text(widget.emoji, style: const TextStyle(fontSize: 28)),
            ),
          ),
        );
      },
    );
  }
}
