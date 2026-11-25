import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Premiere's screen-recording blackout (docs/plans/studio-modes.md, phase 8).
///
/// While any film player holds it: Android sets FLAG_SECURE (recordings and
/// screenshots come out black), macOS takes the window out of screen sharing
/// and capture, and iOS reports when the screen is being recorded or mirrored
/// so the player can cover the film. None of this stops someone filming the
/// screen with another device.
abstract final class CaptureGuard {
  static const _channel = MethodChannel('nile/capture_guard');

  /// iOS: the screen is being recorded, mirrored or AirPlayed right now.
  static final captured = ValueNotifier<bool>(false);

  static int _holds = 0;
  static bool _listening = false;

  /// Ref-counted: every [hold] needs its [release].
  static Future<void> hold() async {
    if (_holds++ > 0) return;
    await _set(true);
  }

  static Future<void> release() async {
    if (_holds == 0 || --_holds > 0) return;
    await _set(false);
  }

  static Future<void> _set(bool on) async {
    if (kIsWeb) return;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'captured') captured.value = call.arguments == true;
      });
    }
    try {
      final r = await _channel.invokeMethod<bool>('protect', on);
      captured.value = on && r == true;
    } on MissingPluginException {
      // Platforms with nothing to do (Linux, Windows, tests).
    } on PlatformException {
      // Best effort: playback never fails because protection couldn't start.
    }
  }

  @visibleForTesting
  static void debugReset() {
    _holds = 0;
    captured.value = false;
  }
}
