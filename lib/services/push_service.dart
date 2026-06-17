import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../screens/conversation_screen.dart';
import '../screens/event_detail_screen.dart';
import '../screens/post_detail_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/viewer_screen.dart';
import 'device_token_service.dart';
import 'event_service.dart';
import 'message_service.dart';
import 'post_service.dart';
import 'profile_service.dart';
import 'supabase_client.dart';

/// Background isolate handler. Must be a top-level function. We intentionally do
/// nothing here: the OS displays the notification from the FCM payload, and tap
/// routing is handled when the app resumes via getInitialMessage / onMessageOpenedApp.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage _) async {}

/// Owns FCM lifecycle: permission, token registration/refresh, and routing a
/// notification tap to the right screen. Deep-link routing mirrors
/// NotificationsScreen._tap so in-app and push taps land identically.
class PushService {
  static GlobalKey<NavigatorState>? _navKey;
  static String? _token;
  static bool _started = false;

  /// Call once after Firebase.initializeApp, passing the app's navigatorKey.
  static Future<void> init(GlobalKey<NavigatorState> navKey) async {
    if (kIsWeb) return;
    if (_started) return;
    _started = true;
    _navKey = navKey;

    FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

    final messaging = FirebaseMessaging.instance;
    // Only auto-prompt users who have already been through onboarding — new
    // users get the OS permission prompt at a deliberate moment (the push
    // step of OnboardingScreen) instead of silently at app start.
    if (supabase.auth.currentUser != null &&
        await ProfileService.isOnboarded()) {
      await messaging.requestPermission();
    }

    // Foreground notifications: show the iOS system banner instead of swallowing.
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Route a tap that launched the app from terminated state.
    final initial = await messaging.getInitialMessage();
    if (initial != null) _handleTap(initial.data);

    // Route a tap while the app was backgrounded.
    FirebaseMessaging.onMessageOpenedApp.listen((m) => _handleTap(m.data));

    // Keep the stored token current.
    messaging.onTokenRefresh.listen(_saveToken);

    final token = await messaging.getToken();
    if (token != null) await _saveToken(token);
  }

  /// Fire the OS notification-permission prompt and register the token on
  /// grant. Used by the onboarding push step. Returns true if authorized.
  static Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (granted) {
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);
    }
    return granted;
  }

  /// Register the current token for the signed-in user. Call on sign-in.
  static Future<void> onSignIn() async {
    if (kIsWeb) return;
    final token = _token ?? await FirebaseMessaging.instance.getToken();
    if (token != null) await _saveToken(token);
  }

  /// Drop this device's token on sign-out.
  static Future<void> onSignOut() async {
    if (kIsWeb) return;
    if (_token != null) await DeviceTokenService.unregister(_token!);
  }

  static Future<void> _saveToken(String token) async {
    _token = token;
    await DeviceTokenService.register(token);
  }

  // ── Deep-link routing ──────────────────────────────────────────────────────

  static Future<void> _handleTap(Map<String, dynamic> data) async {
    final nav = _navKey?.currentState;
    if (nav == null) return;
    // FCM delivers all data values as strings; entity_id is "" when null.
    final type = data['type'] as String?;
    final rawEntity = data['entity_id'] as String?;
    final entityId = (rawEntity == null || rawEntity.isEmpty)
        ? null
        : rawEntity;
    final actorId = data['actor_id'] as String?;

    // A notification tap is an external entry point — land on a fresh stack.
    // Tapping several notifications in a row would otherwise pile duplicate
    // screens on top of each other (worst case: a second live ViewerScreen,
    // i.e. two simultaneous LiveKit connections).
    void pushFresh(Route<void> route) {
      nav.popUntil((r) => r.isFirst);
      nav.push(route);
    }

    switch (type) {
      case 'post_like':
      case 'post_comment':
        if (entityId == null) return;
        final post = await PostService.fetchById(entityId);
        if (post == null) return;
        pushFresh(
          MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
        );
      case 'follow':
        if (actorId == null) return;
        pushFresh(
          MaterialPageRoute(builder: (_) => ProfileScreen(userId: actorId)),
        );
      case 'event_starting':
      case 'event_live':
      case 'event_ended':
      case 'operator_assigned':
        if (entityId == null) return;
        final event = await EventService.fetchById(entityId);
        if (event == null) return;
        pushFresh(
          MaterialPageRoute(
            builder: (_) => event.isLive
                ? ViewerScreen(initialEventId: event.liveKitEventId)
                : EventDetailScreen(event: event),
          ),
        );
      case 'new_message':
        // actor_id is the sender; resolve (or reuse) the conversation by it.
        if (actorId == null) return;
        final conv = await MessageService.getOrCreate(actorId);
        pushFresh(
          MaterialPageRoute(
            builder: (_) => ConversationScreen(conversation: conv),
          ),
        );
    }
  }
}
