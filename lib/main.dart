import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/auth/claim_username_screen.dart';
import 'screens/auth/feature_intro_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/mfa_challenge_screen.dart';
import 'screens/auth/onboarding_screen.dart';
import 'screens/auth/reset_password_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'services/app_lifecycle.dart';
import 'services/connectivity_service.dart';
import 'services/deep_link_service.dart';
import 'services/mfa_service.dart';
import 'services/profile_service.dart';
import 'services/push_service.dart';
import 'services/theme_service.dart';
import 'theme.dart';
import 'widgets/force_update_gate.dart';

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
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // One app-level lifecycle observer feeds AppLifecycle; screens listen there
    // to refresh/re-subscribe on resume rather than each registering their own.
    WidgetsBinding.instance.addObserver(this);
    // Initialize FCM after first frame so the navigator is mounted for routing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_firebaseSupported) PushService.init(_navigatorKey);
      DeepLinkService.init(_navigatorKey);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      builder: (_, themeMode, _) => MaterialApp(
        title: 'Nile',
        debugShowCheckedModeBanner: false,
        theme: nileTheme(Brightness.light),
        darkTheme: nileTheme(Brightness.dark),
        themeMode: themeMode,
        // Allow mouse + trackpad drag to scroll (and so drive RefreshIndicator)
        // on web/desktop, where only touch is enabled by default.
        scrollBehavior: const _NileScrollBehavior(),
        navigatorKey: _navigatorKey,
        // Startup version gate wraps the whole app (fails open on any error).
        home: ForceUpdateGate(
          child: _AuthGate(navigatorKey: _navigatorKey),
        ),
      ),
    );
  }
}

/// Listens to Supabase auth state and routes accordingly.
/// - Authenticated, onboarded     → HomeScreen
/// - Authenticated, not onboarded → OnboardingScreen (onboarded_at IS NULL)
/// - Unauthenticated, first launch → FeatureIntroScreen (native apps only, once)
/// - Unauthenticated              → LoginScreen
///
/// On sign-out, also clears any pushed routes (e.g. Settings) so the user
/// is returned to the gate rather than left stranded on a stale screen.
class _AuthGate extends StatefulWidget {
  const _AuthGate({required this.navigatorKey});
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  // Minimum time the splash stays visible on cold start, so it doesn't flash
  // past (or get skipped entirely) when a session is restored synchronously.
  // On web, skip the splash entirely when a session already exists — a page
  // refresh shouldn't replay the intro screen.
  static const _minSplash = Duration(milliseconds: 1500);

  late final StreamSubscription<AuthState> _sub;
  // Cancellable (unlike Future.delayed) so dispose leaves no pending timer —
  // flutter_test fails any test that tears down the tree with one outstanding.
  Timer? _splashTimer;
  Session? _session;
  bool _initialized = false;
  bool _splashDone = false;
  // null = unknown (fetch in flight or no session); the splash covers latency.
  // Carries both onboarding state and whether an OAuth signup still holds an
  // auto-generated username that must be claimed first.
  ({bool onboarded, bool needsUsernameClaim})? _gate;
  // First-launch feature tour. null = local flag still being read; the splash
  // covers it. Only ever consulted while signed out.
  bool? _introSeen;

  /// The tour runs on the native app builds (mobile + macOS). Web has the
  /// marketing site instead, and its async session restore would flash the
  /// tour on every refresh.
  static bool get _introSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Fetch onboarding + username-claim state for the current session and cache
  /// it. Guarded against stale responses when the user changes mid-flight.
  Future<void> _resolveGate() async {
    final uid = _session?.user.id;
    if (uid == null) return;
    final gate = await ProfileService.gateState();
    if (mounted && _session?.user.id == uid) {
      setState(() => _gate = gate);
    }
  }

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;
    // A synchronously-restored session won't necessarily re-emit on the auth
    // stream, so treat its presence as already-resolved.
    _initialized = _session != null;
    if (_session != null) {
      _resolveGate();
      // New device with empty local prefs: adopt profiles.theme_mode.
      ThemeService.instance.onSignIn();
    }
    if (!_introSupported) {
      _introSeen = true;
    } else if (_session != null) {
      // Already signed in, so this is an existing user updating the app:
      // stamp the flag now rather than showing them the tour if they sign out.
      _introSeen = true;
      FeatureIntroScreen.markSeen();
    } else {
      FeatureIntroScreen.hasSeen().then((seen) {
        if (mounted) setState(() => _introSeen = seen);
      });
    }
    // On web, skip the splash entirely — the session is restored asynchronously
    // via the auth stream (currentSession is always null at initState on web),
    // so the minimum-duration guard never fires correctly. Web has no native
    // launch screen, so just show a bare loading indicator until auth resolves.
    if (kIsWeb) {
      _splashDone = true;
    } else {
      _splashTimer = Timer(_minSplash, () {
        if (mounted) setState(() => _splashDone = true);
      });
    }
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      final nav = widget.navigatorKey.currentState;
      // Only the root-swap events clear the pushed stack. In particular, do NOT
      // pop on tokenRefreshed / mfaChallengeVerified / userUpdated — those fire
      // mid-flow during MFA enroll/verify/recovery, and popping would tear the
      // user out of the enrollment or recovery screen they're standing on.
      switch (state.event) {
        case AuthChangeEvent.signedIn:
          nav?.popUntil((r) => r.isFirst);
          PushService.onSignIn();
          ThemeService.instance.onSignIn();
          _gate = null; // fresh signup/sign-in: re-check below
        case AuthChangeEvent.signedOut:
          nav?.popUntil((r) => r.isFirst);
          PushService.onSignOut();
          _gate = null;
          // Debug builds only: Settings has a "Replay feature intro" row that
          // clears the local flag then signs out, so re-read it here rather
          // than trusting the cached value. Production never resets the flag,
          // so this never fires there and stays a one-time-per-device check.
          if (kDebugMode && _introSupported) {
            _introSeen = null;
            FeatureIntroScreen.hasSeen().then((seen) {
              if (mounted) setState(() => _introSeen = seen);
            });
          }
        case AuthChangeEvent.passwordRecovery:
          // Opened a recovery link: force the set-new-password screen on top of
          // whatever the gate resolves to underneath.
          nav?.popUntil((r) => r.isFirst);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.navigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
            );
          });
        default:
          break;
      }
      setState(() {
        _session = state.session;
        _initialized = true;
      });
      if (_session != null && _gate == null) _resolveGate();
    });
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
    _sub.cancel();
    super.dispose();
  }

  /// Leave the tour for good. [startSignup] comes from the closing CTA, and
  /// pushes signup on top of the login screen the gate falls through to.
  void _dismissIntro(bool startSignup) {
    FeatureIntroScreen.markSeen();
    setState(() => _introSeen = true);
    if (!startSignup) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const SignupScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Before the first auth event resolves with no existing session, show a
    // loader to avoid a flash of the wrong route.
    // Hold the splash until both the minimum duration has elapsed and the
    // first auth event has resolved.
    if (!_splashDone || !_initialized) {
      return const SplashScreen();
    }
    if (_session == null) {
      // Hold the splash while the local seen-flag resolves, so the tour never
      // flashes in behind the login screen.
      if (_introSeen == null) return const SplashScreen();
      if (!_introSeen!) return FeatureIntroScreen(onDone: _dismissIntro);
      return const LoginScreen();
    }
    // Session present but at aal1 with a verified factor pending — challenge for
    // the second step before anything else (also covers cold-start restore).
    if (MfaService.needsChallenge()) {
      return MfaChallengeScreen(onVerified: () => setState(() {}));
    }
    // Session present but gate state still loading — hold the splash.
    final gate = _gate;
    if (gate == null) return const SplashScreen();
    // OAuth signup holding a generated username: claim screen comes before
    // onboarding, and there is no way around it.
    if (gate.needsUsernameClaim) {
      return ClaimUsernameScreen(
        onDone: () => setState(
          () => _gate = (onboarded: gate.onboarded, needsUsernameClaim: false),
        ),
      );
    }
    if (!gate.onboarded) {
      return OnboardingScreen(
        onDone: () => setState(
          () => _gate = (onboarded: true, needsUsernameClaim: false),
        ),
      );
    }
    return const HomeScreen();
  }
}
