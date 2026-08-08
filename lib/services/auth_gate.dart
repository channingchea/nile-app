import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/auth/feature_intro_screen.dart';
import 'mfa_service.dart';
import 'profile_service.dart';
import 'push_service.dart';
import 'theme_service.dart';

/// Where the gate says the user is currently allowed to be.
///
/// This used to be a widget (`_AuthGate` in main.dart) that returned a
/// different subtree for the same route. Under a router the same ladder has to
/// be answerable *synchronously*, from outside the tree, so the router's
/// `redirect` can consult it — hence a ChangeNotifier holding the state and a
/// pure function turning it into a location.
enum GateStage { splash, intro, signedOut, mfaChallenge, claimUsername, onboarding, ready }

/// Auth + onboarding state, hoisted out of the widget tree so `GoRouter`'s
/// redirect can read it and its `refreshListenable` can react to it.
class AuthGate extends ChangeNotifier {
  AuthGate._();
  static final AuthGate instance = AuthGate._();

  /// Minimum time the splash stays visible on cold start, so it doesn't flash
  /// past when a session is restored synchronously.
  static const _minSplash = Duration(milliseconds: 1500);

  StreamSubscription<AuthState>? _sub;
  Timer? _splashTimer;

  Session? _session;
  bool _initialized = false;
  bool _splashDone = false;
  ({bool onboarded, bool needsUsernameClaim})? _gate;
  bool? _introSeen;

  /// Set when a recovery link arrives, cleared once the password is changed.
  /// Outranks everything below the splash: the user opened a link specifically
  /// to set a new password.
  bool _passwordRecovery = false;

  /// Set by the feature tour's closing CTA so the router can land on signup
  /// rather than login.
  bool _introWantsSignup = false;

  bool get isSignedIn => _session != null;
  bool get passwordRecovery => _passwordRecovery;
  bool get introWantsSignup => _introWantsSignup;

  /// The tour runs on the native app builds (mobile + macOS). Web has the
  /// marketing site instead, and its async session restore would flash the
  /// tour on every refresh.
  static bool get introSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// The single decision the router asks about. Order is load-bearing and
  /// matches the old widget ladder exactly.
  GateStage get stage {
    if (!_splashDone || !_initialized) return GateStage.splash;
    if (_session == null) {
      if (_introSeen == null) return GateStage.splash;
      if (!_introSeen!) return GateStage.intro;
      return GateStage.signedOut;
    }
    if (_passwordRecovery) return GateStage.ready;
    if (MfaService.needsChallenge()) return GateStage.mfaChallenge;
    final gate = _gate;
    if (gate == null) return GateStage.splash;
    if (gate.needsUsernameClaim) return GateStage.claimUsername;
    if (!gate.onboarded) return GateStage.onboarding;
    return GateStage.ready;
  }

  void start() {
    if (_sub != null) return;
    _session = Supabase.instance.client.auth.currentSession;
    // A synchronously-restored session won't necessarily re-emit on the auth
    // stream, so treat its presence as already-resolved.
    _initialized = _session != null;
    if (_session != null) {
      _resolveGate();
      // New device with empty local prefs: adopt profiles.theme_mode.
      ThemeService.instance.onSignIn();
    }
    if (!introSupported) {
      _introSeen = true;
    } else if (_session != null) {
      // Already signed in, so this is an existing user updating the app: stamp
      // the flag now rather than showing them the tour if they sign out.
      _introSeen = true;
      FeatureIntroScreen.markSeen();
    } else {
      FeatureIntroScreen.hasSeen().then((seen) {
        _introSeen = seen;
        notifyListeners();
      });
    }
    // On web the session is restored asynchronously via the auth stream
    // (currentSession is always null at start), so the minimum-duration guard
    // never fires correctly — skip the splash entirely there.
    if (kIsWeb) {
      _splashDone = true;
    } else {
      _splashTimer = Timer(_minSplash, () {
        _splashDone = true;
        notifyListeners();
      });
    }

    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      // Only the root-swap events reset the gate. In particular do NOT react to
      // tokenRefreshed / mfaChallengeVerified / userUpdated — those fire
      // mid-flow during MFA enroll/verify/recovery, and resetting would tear
      // the user out of the screen they are standing on.
      switch (state.event) {
        case AuthChangeEvent.signedIn:
          PushService.onSignIn();
          ThemeService.instance.onSignIn();
          _gate = null; // fresh signup/sign-in: re-check below
        case AuthChangeEvent.signedOut:
          PushService.onSignOut();
          _gate = null;
          _passwordRecovery = false;
          _introWantsSignup = false;
          // Debug builds only: Settings has a "Replay feature intro" row that
          // clears the local flag then signs out, so re-read it here rather
          // than trusting the cached value.
          if (kDebugMode && introSupported) {
            _introSeen = null;
            FeatureIntroScreen.hasSeen().then((seen) {
              _introSeen = seen;
              notifyListeners();
            });
          }
        case AuthChangeEvent.passwordRecovery:
          _passwordRecovery = true;
        default:
          break;
      }
      _session = state.session;
      _initialized = true;
      notifyListeners();
      if (_session != null && _gate == null) _resolveGate();
    });
  }

  /// Fetch onboarding + username-claim state for the current session and cache
  /// it. Guarded against stale responses when the user changes mid-flight.
  Future<void> _resolveGate() async {
    final uid = _session?.user.id;
    if (uid == null) return;
    final gate = await ProfileService.gateState();
    if (_session?.user.id == uid) {
      _gate = gate;
      notifyListeners();
    }
  }

  /// The MFA challenge passed. [MfaService.needsChallenge] is a synchronous read
  /// of the SDK's cached AAL and nothing notifies when it changes, so the screen
  /// tells us by hand.
  void mfaVerified() => notifyListeners();

  void usernameClaimed() {
    final gate = _gate;
    if (gate == null) return;
    _gate = (onboarded: gate.onboarded, needsUsernameClaim: false);
    notifyListeners();
  }

  void onboarded() {
    _gate = (onboarded: true, needsUsernameClaim: false);
    notifyListeners();
  }

  /// Leave the tour for good. [startSignup] comes from the closing CTA and
  /// lands the user on signup instead of login.
  void dismissIntro(bool startSignup) {
    FeatureIntroScreen.markSeen();
    _introSeen = true;
    _introWantsSignup = startSignup;
    notifyListeners();
  }

  /// Consumed by the router once it has honoured the signup CTA, so a later
  /// visit to /login doesn't bounce to signup again.
  void consumeIntroSignup() => _introWantsSignup = false;

  /// The new password was set — release the recovery pin.
  void passwordRecoveryHandled() {
    if (!_passwordRecovery) return;
    _passwordRecovery = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
