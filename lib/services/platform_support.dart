import 'package:flutter/foundation.dart';

/// Feature gates for plugins that have no macOS/desktop implementation.
///
/// These are capability checks, not platform checks — call them where a
/// feature is entered, so the UI hides what would otherwise throw a
/// MissingPluginException.
class NilePlatform {
  NilePlatform._();

  static bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// `video_thumbnail` (the trim-strip frames) has no macOS build, so Currents
  /// can be watched anywhere but only created on a phone.
  static bool get canCreateCurrents => _isMobile;

  /// `sensors_plus` has no macOS implementation — shake-to-report can't arm.
  static bool get hasAccelerometer => _isMobile;
}
