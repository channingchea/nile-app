import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'services/deep_link_service.dart';
import 'services/push_service.dart';
import 'theme.dart';

/// True only on platforms where a Firebase app is configured: web, iOS, Android.
/// macOS and other desktop targets have no registered Firebase app.
bool get _firebaseSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

void main() async {
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
  }

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

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

class _NileAppState extends State<NileApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Initialize FCM after first frame so the navigator is mounted for routing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_firebaseSupported) PushService.init(_navigatorKey);
      DeepLinkService.init(_navigatorKey);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nile',
      debugShowCheckedModeBanner: false,
      theme: nileTheme(),
      // Allow mouse + trackpad drag to scroll (and so drive RefreshIndicator)
      // on web/desktop, where only touch is enabled by default.
      scrollBehavior: const _NileScrollBehavior(),
      navigatorKey: _navigatorKey,
      home: _AuthGate(navigatorKey: _navigatorKey),
    );
  }
}

/// Listens to Supabase auth state and routes accordingly.
/// - Authenticated   → HomeScreen
/// - Unauthenticated → LoginScreen
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
  Session? _session;
  bool _initialized = false;
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;
    // A synchronously-restored session won't necessarily re-emit on the auth
    // stream, so treat its presence as already-resolved.
    _initialized = _session != null;
    // On web, skip the splash entirely — the session is restored asynchronously
    // via the auth stream (currentSession is always null at initState on web),
    // so the minimum-duration guard never fires correctly. Web has no native
    // launch screen, so just show a bare loading indicator until auth resolves.
    if (kIsWeb) {
      _splashDone = true;
    } else {
      Future.delayed(_minSplash, () {
        if (mounted) setState(() => _splashDone = true);
      });
    }
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      // Pop any routes pushed on top of the gate before swapping the root,
      // otherwise a pushed screen (e.g. Settings) stays visible after sign-out.
      widget.navigatorKey.currentState?.popUntil((r) => r.isFirst);
      // Keep the device's push token bound to the right user.
      switch (state.event) {
        case AuthChangeEvent.signedIn:
          PushService.onSignIn();
        case AuthChangeEvent.signedOut:
          PushService.onSignOut();
        default:
          break;
      }
      setState(() {
        _session = state.session;
        _initialized = true;
      });
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
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
    return _session != null ? const HomeScreen() : const LoginScreen();
  }
}
