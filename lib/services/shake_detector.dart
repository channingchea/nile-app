import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_support.dart';

/// Shake-to-report, armed in beta builds only.
///
/// Store builds ship with this off: a phone in a pocket on a bumpy bus clears
/// the threshold regularly, and a report form popping over live video would be
/// worse than the bug it was meant to catch.
///
/// Build a beta with:  flutter build apk --dart-define=NILE_BETA=true
class ShakeDetector {
  ShakeDetector._();
  static final ShakeDetector instance = ShakeDetector._();

  /// Beta gate. `kDebugMode` keeps it available while developing without
  /// needing the define. Also requires an accelerometer — `sensors_plus` has
  /// no macOS implementation, so listening there throws instead of no-oping.
  static bool get enabled =>
      (bool.fromEnvironment('NILE_BETA') || kDebugMode) &&
      NilePlatform.hasAccelerometer;

  /// Acceleration past this (m/s², gravity excluded) counts as a shake.
  static const double _threshold = 22;

  /// One shake per this window — a real shake spans several samples.
  static const Duration _cooldown = Duration(seconds: 3);

  /// Root repaint boundary, used to grab what the user was looking at.
  static final GlobalKey captureKey = GlobalKey();

  static const _consentKey = 'shake_report_consent_v1';

  StreamSubscription<UserAccelerometerEvent>? _sub;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _paused = false;
  VoidCallback? _onShake;

  /// Some screens must never be interrupted: a phone acting as a camera on a
  /// tripod gets knocked constantly, and popping the form would drop the shot.
  void pause() => _paused = true;
  void resume() => _paused = false;

  void start(VoidCallback onShake) {
    if (!enabled || _sub != null) return;
    _onShake = onShake;
    // userAccelerometer excludes gravity, so a still device reads ~0 and the
    // threshold means the same thing whatever way up the phone is held.
    _sub = userAccelerometerEventStream().listen((e) {
      if (_paused) return;
      final g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      if (g < _threshold) return;
      final now = DateTime.now();
      if (now.difference(_last) < _cooldown) return;
      _last = now;
      HapticFeedback.mediumImpact();
      _onShake?.call();
    }, onError: (_) {
      // No accelerometer (simulator, desktop) — nothing to detect.
      stop();
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// One-time consent, because the capture happens before the user has a
  /// chance to look at what's on screen.
  static Future<bool> hasConsented() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_consentKey) ?? false;
  }

  static Future<void> markConsented() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_consentKey, true);
  }

  /// PNG of the current frame, or null if the tree isn't ready. Uses the root
  /// RepaintBoundary directly — no extra plugin needed for this.
  static Future<Uint8List?> capture() async {
    try {
      final obj = captureKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return null;
      final image = await obj.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
