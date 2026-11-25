import 'package:flutter/foundation.dart';

/// Studio element HUD (docs/plans/studio-element-hud.md): what a kind's
/// quick-control card holds, as plain data. Native kinds build these in Dart;
/// a plugin element will send the same thing as JSON, and the Studio draws
/// both with one widget — no plugin code ever runs.
///
/// Actions are named by id. A timer's start sends its seconds (or nothing);
/// an input sends what was typed, parsed; every other action sends nothing.

enum HudStyle { primary, danger, outlined, text }

enum HudTone { normal, accent, dim }

@immutable
sealed class HudItem {
  const HudItem();

  Map<String, dynamic> toJson();

  /// One item off the wire; null for anything this build doesn't know.
  static HudItem? fromJson(Object? j) {
    if (j is! Map) return null;
    String? str(String k) => j[k] is String ? j[k] as String : null;
    int? integer(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    final action = str('action');
    return switch (j['type']) {
      'button' when action != null && str('label') != null => HudButton(
        action: action,
        label: str('label')!,
        icon: str('icon'),
        style: _enum(HudStyle.values, j['style'], HudStyle.outlined),
        active: j['active'] is bool ? j['active'] as bool : null,
        enabled: j['enabled'] != false,
        confirm: str('confirm'),
      ),
      'timer' when str('start') != null => HudTimer(
        start: str('start')!,
        stop: str('stop'),
        running: j['running'] == true,
        ms: integer('ms'),
        presets: [
          if (j['presets'] case final List p)
            for (final s in p)
              if (s is num && s > 0) s.toInt(),
        ],
        defaultSec: integer('defaultSec'),
        startLabel: str('startLabel') ?? 'Timer',
        stopLabel: str('stopLabel') ?? 'Stop',
      ),
      'readout' when str('text') != null => HudReadout(
        str('text')!,
        tone: _enum(HudTone.values, j['tone'], HudTone.normal),
        strong: j['strong'] == true,
      ),
      'input' when action != null && str('label') != null => HudInput(
        action: action,
        label: str('label')!,
        number: j['number'] == true,
        value: str('value') ?? '',
        min: j['min'] is num ? j['min'] as num : null,
        max: j['max'] is num ? j['max'] as num : null,
        maxLength: integer('maxLength'),
      ),
      _ => null,
    };
  }

  static List<HudItem> listFromJson(Object? j) => [
    if (j is List)
      for (final i in j) ?fromJson(i),
  ];
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

/// A button; [active] non-null makes it a toggle (filled when on).
class HudButton extends HudItem {
  const HudButton({
    required this.action,
    required this.label,
    this.icon,
    this.style = HudStyle.outlined,
    this.active,
    this.enabled = true,
    this.confirm,
  });

  final String action;
  final String label;

  /// A name from the HUD's small icon set ("check", "visibility"…).
  final String? icon;
  final HudStyle style;
  final bool? active;
  final bool enabled;

  /// Asked first ("Clear every vote?"); null = runs at once.
  final String? confirm;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'button',
    'action': action,
    'label': label,
    'icon': ?icon,
    'style': style.name,
    'active': ?active,
    if (!enabled) 'enabled': false,
    'confirm': ?confirm,
  };
}

/// A countdown or clock: its reading and Stop while it runs; otherwise a
/// preset menu (or a plain Start when there are no presets).
class HudTimer extends HudItem {
  const HudTimer({
    required this.start,
    this.stop,
    this.running = false,
    this.ms,
    this.presets = const [],
    this.defaultSec,
    this.startLabel = 'Timer',
    this.stopLabel = 'Stop',
  });

  final String start;
  final String? stop;
  final bool running;

  /// What it reads now (left or elapsed); null = nothing to show.
  final int? ms;

  /// Lengths offered, in seconds.
  final List<int> presets;
  final int? defaultSec;
  final String startLabel;
  final String stopLabel;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'timer',
    'start': start,
    'stop': ?stop,
    if (running) 'running': true,
    'ms': ?ms,
    if (presets.isNotEmpty) 'presets': presets,
    'defaultSec': ?defaultSec,
    'startLabel': startLabel,
    'stopLabel': stopLabel,
  };
}

/// A number or short text from the element, on the card's bottom line.
class HudReadout extends HudItem {
  const HudReadout(
    this.text, {
    this.tone = HudTone.normal,
    this.strong = false,
  });

  final String text;
  final HudTone tone;
  final bool strong;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'readout',
    'text': text,
    'tone': tone.name,
    if (strong) 'strong': true,
  };
}

/// A small text or number field; sends on Enter or when it loses focus.
class HudInput extends HudItem {
  const HudInput({
    required this.action,
    required this.label,
    this.number = false,
    this.value = '',
    this.min,
    this.max,
    this.maxLength,
  });

  final String action;
  final String label;
  final bool number;

  /// What the field starts with.
  final String value;
  final num? min;
  final num? max;
  final int? maxLength;

  /// What to send for [raw]: a clamped number, or trimmed text; null =
  /// nothing worth sending.
  Object? parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (!number) {
      final n = maxLength;
      return n != null && t.length > n ? t.substring(0, n) : t;
    }
    var v = num.tryParse(t);
    if (v == null) return null;
    if (min != null && v < min!) v = min!;
    if (max != null && v > max!) v = max!;
    return v == v.roundToDouble() ? v.toInt() : v;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'input',
    'action': action,
    'label': label,
    if (number) 'number': true,
    if (value.isNotEmpty) 'value': value,
    'min': ?min,
    'max': ?max,
    'maxLength': ?maxLength,
  };
}
