import 'package:flutter/services.dart';

/// RealSync's native hook: hold one remote WebRTC receiver's playout back by a
/// minimum delay (libwebrtc's jitter-buffer minimum). iOS, macOS and Android.
///
/// The hook reaches into libwebrtc through a vtable slot, so it is guarded: on
/// iOS/macOS [unavailableReason] proves the slot against the loaded binary at
/// first use; on Android each receiver is checked before its first call.
/// Anything that fails reports unavailable and the caller falls back.
class NileRealSync {
  NileRealSync._();

  static const _channel = MethodChannel('nile_realsync');
  static Future<String?>? _selfTest;

  /// Null when the hook can be used; otherwise why not. Run once per launch.
  static Future<String?> unavailableReason() => _selfTest ??= _runSelfTest();

  static Future<String?> _runSelfTest() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('selfTest');
      if (r?['ok'] == true) return null;
      return (r?['reason'] as String?) ?? 'self-test failed';
    } on MissingPluginException {
      return 'unsupported platform';
    } catch (e) {
      return 'self-test error: $e';
    }
  }

  /// Hold [receiverId]'s playout back by at least [delay]; null clears it.
  /// Returns false when the receiver wasn't found or the hook is unavailable.
  static Future<bool> setMinimumPlayoutDelay(
    String receiverId,
    Duration? delay,
  ) async {
    if (await unavailableReason() != null) return false;
    try {
      return await _channel.invokeMethod<bool>('setMinimumPlayoutDelay', {
            'receiverId': receiverId,
            'seconds': delay == null ? null : delay.inMicroseconds / 1e6,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
