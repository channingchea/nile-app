import 'package:flutter/services.dart';

/// RealSync's native side, on iOS, macOS and Android:
///  - hold one remote WebRTC receiver's playout back by a minimum delay
///    (libwebrtc's jitter-buffer minimum), and
///  - capture stamps: every published frame carries its sender's wall clock
///    (LiveKit's packet-trailer format; Opus padding for audio), and viewers
///    read how old each stream's frames are when they arrive.
///
/// Both reach into libwebrtc through vtable slots, so both are guarded: on
/// iOS/macOS the self-tests prove the slots against the loaded binary at first
/// use; on Android each native object is checked before its first call.
/// Anything that fails reports unavailable and the caller falls back.
class NileRealSync {
  NileRealSync._();

  static const _channel = MethodChannel('nile_realsync');
  static Future<String?>? _selfTest;
  static Future<String?>? _stampSelfTest;

  /// Null when the delay hook can be used; otherwise why not. Once per launch.
  static Future<String?> unavailableReason() =>
      _selfTest ??= _runSelfTest('selfTest');

  /// Null when capture stamps can be used; otherwise why not. Once per launch.
  static Future<String?> stampUnavailableReason() =>
      _stampSelfTest ??= _runSelfTest('stampSelfTest');

  static Future<String?> _runSelfTest(String method) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(method);
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

  /// Stamp every frame flutter_webrtc's sender [senderId] sends. False when
  /// it can't (yet) — an audio sender before its codecs are negotiated too.
  static Future<bool> stampSender(String senderId, {required bool audio}) =>
      _attach('stampSender', senderId, audio);

  /// Read the stamps arriving at receiver [receiverId].
  static Future<bool> readReceiver(String receiverId, {required bool audio}) =>
      _attach('readReceiver', receiverId, audio);

  static Future<bool> _attach(String method, String id, bool audio) async {
    if (await stampUnavailableReason() != null) return false;
    try {
      return await _channel.invokeMethod<bool>(method, {'id': id, 'audio': audio}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Stop stamping/reading [id] and drop its readings.
  static Future<void> forget(String id) async {
    try {
      await _channel.invokeMethod<void>('forget', {'id': id});
    } catch (_) {}
  }

  /// For each receiver with stamped frames in the last [windowMs]: the median
  /// arrival age (this device's clock − the sender's stamp) and how many.
  static Future<Map<String, ({double ageMs, int count})>> ages(
    List<String> receiverIds, {
    int windowMs = 1500,
  }) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('ages', {
        'ids': receiverIds,
        'windowMs': windowMs,
      });
      return {
        for (final e in (r ?? const {}).entries)
          if (e.value case {'ageMs': final num age, 'count': final num n})
            e.key: (ageMs: age.toDouble(), count: n.toInt()),
      };
    } catch (_) {
      return const {};
    }
  }
}
