import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'router.dart';
import 'services/auth_gate.dart';
import 'services/app_lifecycle.dart';
import 'services/connectivity_service.dart';
import 'services/deep_link_service.dart';
import 'services/error_log.dart';
import 'services/nile_shortcuts.dart';
import 'services/push_service.dart';
import 'services/shake_detector.dart';
import 'services/theme_service.dart';
import 'theme.dart';
import 'services/feedback_service.dart';
import 'widgets/force_update_gate.dart';
import 'widgets/nile_mini_player.dart';

/// True only on platforms where a Firebase app is configured: web, iOS, Android.
/// macOS and other desktop targets have no registered Firebase app.
bool get _firebaseSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

void main() async {
  // Crash/error reporting (roadmap #4 observability). Inert without a DSN.
  // SentryFlutter.init hooks FlutterError.onError + PlatformDispatcher.onError,
  // so uncaught errors anywhere in the app are reported automatically.
  if (sentryDsn.isNotEmpty) {
    await SentryFlutter.init((options) {
      options.dsn = sentryDsn;
      options.environment = kDebugMode ? 'debug' : 'production';
      options.tracesSampleRate = 0.2; // light performance sampling
    }, appRunner: _bootstrap);
  } else {
    await _bootstrap();
  }
}

Future<void> _bootstrap() async {
  // Must run INSIDE the Sentry zone (appRunner) — initializing the binding in
  // main() and then calling runApp here throws "Zone mismatch" (FLUTTER-1).
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the last handful of uncaught errors in memory so a bug report can say
  // what actually blew up. Installed AFTER Sentry so it chains onto Sentry's
  // handlers rather than displacing them.
  ErrorLog.install();

  // Firebase (FCM) is only configured for web, iOS, and Android. Desktop
  // targets (macOS) have no Firebase app registered, so initializing there
  // throws and blocks startup — skip it. Push is gated the same way.
  if (_firebaseSupported) {
    await Firebase.initializeApp(
      options: kIsWeb
          ? const FirebaseOptions(
              apiKey: 'AIzaSyDnPP2MUxzMFVwrb-3B_R2JsCnIbU6g1RU',
              authDomain: 'nile-35c48.firebaseapp.com',
              projectId: 'nile-35c48',
              storageBucket: 'nile-35c48.firebasestorage.app',
              messagingSenderId: '907048556625',
              appId: '1:907048556625:web:dd1819916110d6d5664070',
            )
          : null,
    );

    // Device attestation (bot protection on signup — see human_check.dart).
    // Debug builds use the debug provider; register its printed token under
    // Firebase console → App Check → Apps → Manage debug tokens. Web is
    // skipped until a reCAPTCHA v3 key is configured there.
    if (!kIsWeb) {
      await FirebaseAppCheck.instance.activate(
        androidProvider:
            kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
        appleProvider: kDebugMode
            ? AppleProvider.debug
            : AppleProvider.appAttestWithDeviceCheckFallback,
      );
    }
  }

  // Load the saved theme mode before the first frame paints (no flash).
  await ThemeService.instance.load();

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  // Start watching network reachability so any screen can react to on/offline.
  await ConnectivityService.instance.init();

  // The router's redirect reads this synchronously, so it has to be listening
  // to the auth stream before the first route is resolved.
  AuthGate.instance.start();

  runApp(const NileApp());
}

/// Adds mouse + trackpad to the drag devices so drag-scroll (and pull-to-
/// refresh) works on web and desktop, not just touch.
class _NileScrollBehavior extends MaterialScrollBehavior {
  const _NileScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

class NileApp extends StatefulWidget {
  const NileApp({super.key});

  @override
  State<NileApp> createState() => _NileAppState();
}

class _NileAppState extends State<NileApp> with WidgetsBindingObserver {
  /// Guards against a second shake stacking another report form.
  bool _reportOpen = false;

  @override
  void initState() {
    super.initState();
    // One app-level lifecycle observer feeds AppLifecycle; screens listen there
    // to refresh/re-subscribe on resume rather than each registering their own.
    WidgetsBinding.instance.addObserver(this);
    // ⌘K, Esc and the feed's J/K bindings. Installed here rather than in the
    // desktop shell so they survive route changes and keep working while a
    // detail screen covers the shell.
    if (NileShortcuts.supported) NileShortcuts.install();
    // Initialize FCM after first frame so the navigator is mounted for routing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_firebaseSupported) PushService.init();
      DeepLinkService.init();
      ShakeDetector.instance.start(_onShake);
    });
  }

  @override
  void dispose() {
    ShakeDetector.instance.stop();
    NileShortcuts.uninstall();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Beta builds: a shake opens the report form pre-filled with a capture of
  /// whatever was on screen. Captured BEFORE the consent dialog so the dialog
  /// itself isn't what gets attached; discarded if they decline.
  Future<void> _onShake() async {
    if (_reportOpen) return;
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    // The form inserts as the reporter, so it needs a session.
    if (Supabase.instance.client.auth.currentUser == null) return;

    _reportOpen = true;
    try {
      final shot = await ShakeDetector.capture();
      final consented = await ShakeDetector.hasConsented();
      if (!ctx.mounted) return;
      if (!consented) {
        final ok = await showDialog<bool>(
          context: ctx,
          builder: (d) => AlertDialog(
            backgroundColor: NileColors.bgSurface,
            title: Text('Shake to report', style: NileTextStyles.headingSm()),
            content: Text(
              'Shaking your phone opens a bug report with a screenshot of the '
              'screen you were on. Check it before sending — it could show a '
              'private message or your payout details.',
              style: NileTextStyles.bodySm(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Got it'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await ShakeDetector.markConsented();
      }
      if (!ctx.mounted) return;
      await ctx.push(
        NileRoutes.settingsReport,
        extra: ReportIssueArgs(
          kind: FeedbackKind.bug,
          image: shot,
          source: 'shake',
        ),
      );
    } finally {
      _reportOpen = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLifecycle.instance.state.value = state;
  }

  @override
  void didChangePlatformBrightness() {
    // "System" mode tracks the OS light/dark setting live.
    ThemeService.instance.onPlatformBrightnessChanged();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeService.instance.mode,
      builder: (_, themeMode, _) => MaterialApp.router(
        title: 'Nile',
        debugShowCheckedModeBanner: false,
        theme: nileTheme(Brightness.light),
        darkTheme: nileTheme(Brightness.dark),
        themeMode: themeMode,
        // Allow mouse + trackpad drag to scroll (and so drive RefreshIndicator)
        // on web/desktop, where only touch is enabled by default.
        scrollBehavior: const _NileScrollBehavior(),
        routerConfig: nileRouter,
        // Root repaint boundary so shake-to-report can grab the current frame
        // without a screenshot plugin.
        // The GestureDetector is the global keyboard-dismiss: any tap that no
        // other widget claims (empty space, static text) drops focus, which
        // retracts the keyboard. Taps on text fields/buttons win the gesture
        // arena and are unaffected. Covered by test/keyboard_dismiss_test.dart.
        // The version gate moved in here from `home:` — under a router there is
        // no single home widget to wrap, and this covers every route.
        // NileMiniPlayerHost is outside the router on purpose: detail screens
        // are siblings of the tab shell and cover it completely, so a dock
        // rendered inside the shell would disappear the moment you opened an
        // event — which is exactly the navigation it has to survive.
        builder: (_, child) => GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: RepaintBoundary(
            key: ShakeDetector.captureKey,
            child: NileMiniPlayerHost(
              child: ForceUpdateGate(child: child ?? const SizedBox.shrink()),
            ),
          ),
        ),
      ),
    );
  }
}
