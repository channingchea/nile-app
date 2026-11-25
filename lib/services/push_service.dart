import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import 'app_lifecycle.dart';

import '../router.dart';
import 'destinations.dart';
import 'device_token_service.dart';
import 'profile_service.dart';
import 'supabase_client.dart';

/// Background isolate handler. Must be a top-level function. We intentionally do
/// nothing here: the OS displays the notification from the FCM payload, and tap
/// routing is handled when the app resumes via getInitialMessage / onMessageOpenedApp.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage _) async {}

/// Owns FCM lifecycle: permission, token registration/refresh, and routing a
/// notification tap to the right screen. Tap routing goes through
/// [Destinations], the same mapping NotificationsScreen uses, so in-app and
/// push taps land identically.
class PushService {
  static String? _token;
  static bool _started = false;

  /// Call once after Firebase.initializeApp.
  static Future<void> init() async {
    if (kIsWeb) return;
    if (_started) return;
    _started = true;

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

    await _tryRegisterToken();
    // If registration failed (iOS commonly hasn't received its APNs token yet
    // at cold start), retry whenever the app returns to the foreground so the
    // device eventually lands in device_tokens without needing a fresh launch.
    AppLifecycle.instance.state.addListener(_retryOnResume);
  }

  /// Fetch + store the FCM token, tolerating the platform quirks that used to
  /// silently skip registration (and with it, ALL push delivery):
  /// iOS throws `apns-token-not-set` when getToken() runs before APNs hands
  /// over its token, so wait for it briefly instead of failing once and never
  /// retrying.
  static Future<void> _tryRegisterToken() async {
    try {
      final messaging = FirebaseMessaging.instance;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        String? apns = await messaging.getAPNSToken();
        for (var i = 0; apns == null && i < 10; i++) {
          await Future.delayed(const Duration(seconds: 1));
          apns = await messaging.getAPNSToken();
        }
        // Still no APNs token (permission denied, or push entitlement/APNs key
        // not configured) — bail; the resume listener retries later.
        if (apns == null) return;
      }
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);
    } catch (_) {
      // Swallowed on purpose — retried on resume / sign-in.
    }
  }

  static void _retryOnResume() {
    if (_token == null &&
        AppLifecycle.instance.state.value == AppLifecycleState.resumed &&
        supabase.auth.currentUser != null) {
      _tryRegisterToken();
    }
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
    if (granted) await _tryRegisterToken();
    return granted;
  }

  /// Register the current token for the signed-in user. Call on sign-in.
  static Future<void> onSignIn() async {
    if (kIsWeb) return;
    if (_token != null) {
      await _saveToken(_token!);
    } else {
      await _tryRegisterToken();
    }
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
    // FCM delivers all data values as strings; entity_id is "" when null.
    final type = Destinations.typeFromPush(data['type'] as String?);
    if (type == null) return;
    final rawEntity = data['entity_id'] as String?;
    final entityId = (rawEntity == null || rawEntity.isEmpty)
        ? null
        : rawEntity;

    final destination = await Destinations.forNotification(
      type,
      entityId: entityId,
      actorId: data['actor_id'] as String?,
    );
    if (destination == null) return;

    // A notification tap is an external entry point — land on a fresh stack:
    // `go` replaces what's there, where in-app navigation pushes onto it.
    // Tapping several notifications in a row would otherwise pile duplicate
    // screens on top of each other (worst case: a second live ViewerScreen,
    // i.e. two simultaneous LiveKit connections).
    nileRouter.go(destination.location, extra: destination.extra);
  }
}
