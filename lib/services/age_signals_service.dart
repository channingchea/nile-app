import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// What the platform's app store says about this person's age (P4 phase 1).
///
/// This is the difference between a claim and age assurance: the birthday on
/// the signup form is whatever the user typed, while this comes from the App
/// Store account — and for a child in Family Sharing, from their parent. Texas
/// SB 2420 and the Utah and Louisiana equivalents require the store signal, so
/// Nile asks for it first and only falls back to the birthday picker when the
/// OS can't answer.
enum AgeSignalStatus {
  /// No signal available: iOS below 26, a platform with no such API, or the
  /// store declining to answer in this region. Fall back to the picker.
  unsupported,

  /// The person was asked and said no. Also falls back to the picker — the law
  /// requires us to ask, not to refuse service when they decline.
  declined,

  /// We have a bracket.
  shared,
}

class AgeSignal {
  final AgeSignalStatus status;

  /// Null with [AgeSignalStatus.shared] means under the lowest gate we asked
  /// about — for Nile, under 13.
  final int? lowerBound;
  final int? upperBound;

  /// `selfDeclared`, `guardianDeclared`, `confirmed`, or `unknown`. Worth
  /// storing: "a parent set this" and "he typed it himself" are different
  /// facts, and only one of them is worth much in an audit.
  final String declaration;

  /// A guardian has restricted who this person may communicate with. Drives
  /// the DM and live-chat restrictions in a later phase.
  final bool communicationLimits;

  const AgeSignal({
    required this.status,
    this.lowerBound,
    this.upperBound,
    this.declaration = 'unknown',
    this.communicationLimits = false,
  });

  static const unsupported = AgeSignal(status: AgeSignalStatus.unsupported);

  bool get isShared => status == AgeSignalStatus.shared;

  /// The store answered, and the answer is "younger than the lowest gate".
  bool get isUnderMinimum => isShared && lowerBound == null;
}

class AgeSignalsService {
  static const _channel = MethodChannel('nile/age_signals');

  /// Only iOS carries the native half today. Android arrives with Play Age
  /// Signals once Google grants API access; everything else (web, macOS,
  /// desktop) has no store to ask.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Ask the store for the age bracket. Presents a system sheet, so only call
  /// this at a moment the user understands — the compliance gate, not launch.
  ///
  /// Never throws: every failure is [AgeSignal.unsupported], because the
  /// fallback is always available and a broken signal must not lock anyone out.
  static Future<AgeSignal> request({List<int> gates = const [13, 16, 18]}) async {
    if (!supported) return AgeSignal.unsupported;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'requestAgeRange',
        {'gates': gates},
      );
      if (raw == null) return AgeSignal.unsupported;
      switch (raw['status'] as String?) {
        case 'shared':
          return AgeSignal(
            status: AgeSignalStatus.shared,
            lowerBound: raw['lowerBound'] as int?,
            upperBound: raw['upperBound'] as int?,
            declaration: raw['declaration'] as String? ?? 'unknown',
            communicationLimits: raw['communicationLimits'] as bool? ?? false,
          );
        case 'declined':
          return const AgeSignal(status: AgeSignalStatus.declined);
        default:
          return AgeSignal.unsupported;
      }
    } on PlatformException {
      return AgeSignal.unsupported;
    } on MissingPluginException {
      return AgeSignal.unsupported;
    }
  }

  /// Which age rules the store says apply to THIS user — the app can then
  /// enforce the strict path only where a law actually reaches, rather than
  /// everywhere. Empty on iOS below 26.4 and on every other platform.
  static Future<Set<String>> regulatoryFeatures() async {
    if (!supported) return const {};
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('regulatoryFeatures');
      final features = (raw?['features'] as List?)?.cast<String>() ?? const [];
      return features.toSet();
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }
}
