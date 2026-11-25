import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Studio ↔ camera-phone link (studio-edits plan, phases 6-7).
///
/// Two LiveKit data topics, both addressed to specific participants so a room
/// of viewers never receives them:
///  - [statusTopic]  phone → Studio, lossy: mic level ~8×/s, health every 5 s,
///                   and acks for nudges.
///  - [commandTopic] Studio → one phone, reliable: nudges and remote controls.
///
/// A phone obeys a command only when the sender's server-issued role (token
/// metadata) is `studio` — a viewer can't publish data at all, and another
/// camera operator isn't the control room.
abstract final class StudioLink {
  static const statusTopic = 'nile.status';
  static const commandTopic = 'nile.cmd';

  /// Bumped when a message shape changes incompatibly.
  static const version = 1;

  static const levelEvery = Duration(milliseconds: 125);
  static const healthEvery = Duration(seconds: 5);

  /// A meter with nothing newer than this greys out with "No signal".
  static const levelStale = Duration(seconds: 2);
}

enum ThermalLevel {
  nominal,
  fair,
  serious,
  critical;

  static ThermalLevel? fromWire(Object? s) =>
      ThermalLevel.values.where((t) => t.name == s).firstOrNull;

  bool get isHot => index >= ThermalLevel.serious.index;
}

/// What a phone's camera can be told to do from the Studio.
@immutable
class CameraCaps {
  const CameraCaps({
    this.torch = false,
    this.zoom = false,
    this.focusLock = false,
    this.exposureLock = false,
    this.flip = false,
  });

  final bool torch;
  final bool zoom;
  final bool focusLock;
  final bool exposureLock;
  final bool flip;

  bool get any => torch || zoom || focusLock || exposureLock || flip;

  factory CameraCaps.fromJson(Object? j) => j is Map
      ? CameraCaps(
          torch: j['torch'] == true,
          zoom: j['zoom'] == true,
          focusLock: j['focusLock'] == true,
          exposureLock: j['exposureLock'] == true,
          flip: j['flip'] == true,
        )
      : const CameraCaps();

  Map<String, dynamic> toJson() => {
    if (torch) 'torch': true,
    if (zoom) 'zoom': true,
    if (focusLock) 'focusLock': true,
    if (exposureLock) 'exposureLock': true,
    if (flip) 'flip': true,
  };
}

/// One phone's health report.
@immutable
class CameraHealth {
  const CameraHealth({
    this.battery,
    this.charging = false,
    this.thermal,
    this.width,
    this.height,
    this.fps,
    this.caps = const CameraCaps(),
    this.torchOn = false,
    this.zoom = 1,
    this.focusLocked = false,
    this.exposureLocked = false,
  });

  /// 0-100, or null when the phone can't say.
  final int? battery;
  final bool charging;
  final ThermalLevel? thermal;
  final int? width;
  final int? height;
  final double? fps;
  final CameraCaps caps;
  final bool torchOn;
  final double zoom;
  final bool focusLocked;
  final bool exposureLocked;

  bool get lowBattery => battery != null && battery! < 15 && !charging;

  String? get resolutionLabel {
    if (height == null) return null;
    final p = '${height}p';
    return fps == null ? p : '$p · ${fps!.round()} fps';
  }

  factory CameraHealth.fromJson(Map j) => CameraHealth(
    battery: (j['battery'] as num?)?.toInt(),
    charging: j['charging'] == true,
    thermal: ThermalLevel.fromWire(j['thermal']),
    width: (j['w'] as num?)?.toInt(),
    height: (j['h'] as num?)?.toInt(),
    fps: (j['fps'] as num?)?.toDouble(),
    caps: CameraCaps.fromJson(j['caps']),
    torchOn: j['torch'] == true,
    zoom: (j['zoom'] as num?)?.toDouble() ?? 1,
    focusLocked: j['focusLocked'] == true,
    exposureLocked: j['exposureLocked'] == true,
  );

  Map<String, dynamic> toJson() => {
    'battery': ?battery,
    if (charging) 'charging': true,
    'thermal': ?thermal?.name,
    'w': ?width,
    'h': ?height,
    'fps': ?fps,
    'caps': caps.toJson(),
    if (torchOn) 'torch': true,
    if (zoom != 1) 'zoom': zoom,
    if (focusLocked) 'focusLocked': true,
    if (exposureLocked) 'exposureLocked': true,
  };
}

/// phone → Studio.
sealed class StatusMessage {
  const StatusMessage();

  static StatusMessage? decode(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map) return null;
      return switch (j['t']) {
        'lvl' => LevelMessage(((j['v'] as num?)?.toDouble() ?? 0).clamp(0, 1)),
        'health' => HealthMessage(CameraHealth.fromJson(j)),
        'ack' when j['id'] is String => AckMessage(j['id'] as String),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson();

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(jsonEncode({...toJson(), 'v_': StudioLink.version})),
  );
}

class LevelMessage extends StatusMessage {
  const LevelMessage(this.level);
  final double level;
  @override
  Map<String, dynamic> toJson() => {
    't': 'lvl',
    'v': double.parse(level.clamp(0, 1).toStringAsFixed(3)),
  };
}

class HealthMessage extends StatusMessage {
  const HealthMessage(this.health);
  final CameraHealth health;
  @override
  Map<String, dynamic> toJson() => {'t': 'health', ...health.toJson()};
}

class AckMessage extends StatusMessage {
  const AckMessage(this.id);
  final String id;
  @override
  Map<String, dynamic> toJson() => {'t': 'ack', 'id': id};
}

/// Studio → one phone.
sealed class StudioCommand {
  const StudioCommand();

  static StudioCommand? decode(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map) return null;
      return switch (j['t']) {
        'nudge' when j['id'] is String && j['text'] is String =>
          NudgeCommand(j['id'] as String, cleanNudge(j['text'] as String)),
        'torch' => TorchCommand(j['on'] == true),
        'zoom' => ZoomCommand(((j['v'] as num?)?.toDouble() ?? 1).clamp(1, 10)),
        'lock' => LockCommand(
          focus: j['focus'] == true,
          exposure: j['exposure'] == true,
        ),
        'flip' => const FlipCommand(),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson();

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(jsonEncode({...toJson(), 'v_': StudioLink.version})),
  );

  /// What the operator is told when this happens to their camera. Null for a
  /// nudge, which has its own banner.
  String? get operatorNotice => null;
}

class NudgeCommand extends StudioCommand {
  const NudgeCommand(this.id, this.text);
  final String id;
  final String text;
  @override
  Map<String, dynamic> toJson() => {'t': 'nudge', 'id': id, 'text': text};
}

class TorchCommand extends StudioCommand {
  const TorchCommand(this.on);
  final bool on;
  @override
  Map<String, dynamic> toJson() => {'t': 'torch', 'on': on};
  @override
  String get operatorNotice =>
      on ? 'Studio turned on your flashlight' : 'Studio turned off your flashlight';
}

class ZoomCommand extends StudioCommand {
  const ZoomCommand(this.zoom);
  final double zoom;
  @override
  Map<String, dynamic> toJson() => {'t': 'zoom', 'v': zoom};
  @override
  String get operatorNotice => 'Studio set your zoom to ${zoomLabel(zoom)}';
}

class LockCommand extends StudioCommand {
  const LockCommand({required this.focus, required this.exposure});
  final bool focus;
  final bool exposure;
  @override
  Map<String, dynamic> toJson() => {
    't': 'lock',
    'focus': focus,
    'exposure': exposure,
  };
  @override
  String get operatorNotice => switch ((focus, exposure)) {
    (true, true) => 'Studio locked your focus and exposure',
    (true, false) => 'Studio locked your focus',
    (false, true) => 'Studio locked your exposure',
    (false, false) => 'Studio unlocked your focus and exposure',
  };
}

class FlipCommand extends StudioCommand {
  const FlipCommand();
  @override
  Map<String, dynamic> toJson() => {'t': 'flip'};
  @override
  String get operatorNotice => 'Studio flipped your camera';
}

String zoomLabel(double z) =>
    z == z.roundToDouble() ? '${z.round()}×' : '${z.toStringAsFixed(1)}×';

/// Nudges: the presets on the tile menu, plus custom text up to 80.
abstract final class NudgePresets {
  static const all = [
    'Go wide',
    'Tighter',
    'Check focus',
    'Stand by',
    'Charge soon',
  ];
  static const chargeSoon = 'Charge soon';
  static const maxLength = 80;
}

String cleanNudge(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length > NudgePresets.maxLength
      ? t.substring(0, NudgePresets.maxLength)
      : t;
}

/// Studio alerts — battery under 15%, serious heat, or a poor connection for
/// more than 10 s. Each fires once and stays quiet until the condition clears.
enum CameraAlertKind { battery, heat, signal }

class CameraAlerts {
  static const poorSignalFor = Duration(seconds: 10);

  final Map<String, Set<CameraAlertKind>> _active = {};
  final Map<String, DateTime> _poorSince = {};

  /// Feed a camera's latest state; returns the alerts that just started.
  List<CameraAlertKind> update(
    String identity, {
    CameraHealth? health,
    required bool poorSignal,
    required DateTime now,
  }) {
    if (poorSignal) {
      _poorSince.putIfAbsent(identity, () => now);
    } else {
      _poorSince.remove(identity);
    }
    final since = _poorSince[identity];
    final conditions = <CameraAlertKind, bool>{
      CameraAlertKind.battery: health?.lowBattery ?? false,
      CameraAlertKind.heat: health?.thermal?.isHot ?? false,
      CameraAlertKind.signal:
          since != null && now.difference(since) >= poorSignalFor,
    };
    final active = _active.putIfAbsent(identity, () => {});
    final fired = <CameraAlertKind>[];
    conditions.forEach((kind, on) {
      if (on && active.add(kind)) fired.add(kind);
      if (!on) active.remove(kind);
    });
    return fired;
  }

  bool isActive(String identity, CameraAlertKind kind) =>
      _active[identity]?.contains(kind) ?? false;

  void forget(String identity) {
    _active.remove(identity);
    _poorSince.remove(identity);
  }
}

/// Battery and heat for this device (ios/macos/android `nile/device_status`).
/// Every field is null where the platform can't say.
class DeviceStatus {
  static const _channel = MethodChannel('nile/device_status');

  static Future<({int? battery, bool charging, ThermalLevel? thermal})>
  read() async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('read');
      return (
        battery: (r?['battery'] as num?)?.toInt(),
        charging: r?['charging'] == true,
        thermal: ThermalLevel.fromWire(r?['thermal']),
      );
    } catch (_) {
      return (battery: null, charging: false, thermal: null);
    }
  }
}
