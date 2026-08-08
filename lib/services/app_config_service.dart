import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:package_info_plus/package_info_plus.dart';

import 'net.dart';
import 'supabase_client.dart';

/// Result of comparing the running build against the server's `app_config`.
class AppUpdateStatus {
  /// Running build is below `min_build` — the app must be updated to continue.
  final bool blocked;

  /// Running build is below `latest_build` — a non-blocking "update available".
  final bool updateAvailable;

  /// Optional message from config (e.g. why an update is required).
  final String? message;

  /// Optional store/download URL to open from the update prompt.
  final String? updateUrl;

  /// Newest published build for this platform. Used to remember which version
  /// a user has already declined, so the prompt asks once rather than nagging.
  final int latestBuild;

  const AppUpdateStatus({
    required this.blocked,
    required this.updateAvailable,
    this.message,
    this.updateUrl,
    this.latestBuild = 0,
  });

  /// The all-clear: nothing to prompt.
  const AppUpdateStatus.ok()
      : blocked = false,
        updateAvailable = false,
        message = null,
        updateUrl = null,
        latestBuild = 0;
}

/// Startup version gate. Reads the singleton `app_config` row and compares it to
/// the running build number.
///
/// macOS is versioned separately (`macos_min_build` / `macos_latest_build`).
/// It ships as a direct download on its own cadence, so an iOS TestFlight bump
/// must not tell every Mac user their app is stale.
///
/// Fails **open**: any error (offline, missing row, unparsable build) returns
/// [AppUpdateStatus.ok] so a config problem can never brick the app. Web is
/// never gated — it always serves the latest build on reload.
class AppConfigService {
  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<AppUpdateStatus> check() async {
    if (kIsWeb) return const AppUpdateStatus.ok();
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final rows = await supabase
          .from('app_config')
          .select('min_build, latest_build, update_url, message, '
              'macos_min_build, macos_latest_build, macos_update_url')
          .eq('id', 1)
          .limit(1)
          .timeout(kNetTimeout);
      if (rows.isEmpty) return const AppUpdateStatus.ok();
      final cfg = rows.first;
      final mac = _isMacOS;
      final minBuild =
          (cfg[mac ? 'macos_min_build' : 'min_build'] as num?)?.toInt() ?? 0;
      final latestBuild =
          (cfg[mac ? 'macos_latest_build' : 'latest_build'] as num?)?.toInt() ??
              0;
      final url = (mac ? cfg['macos_update_url'] as String? : null) ??
          cfg['update_url'] as String?;
      return AppUpdateStatus(
        blocked: current < minBuild,
        updateAvailable: current < latestBuild,
        message: cfg['message'] as String?,
        updateUrl: url,
        latestBuild: latestBuild,
      );
    } catch (_) {
      return const AppUpdateStatus.ok();
    }
  }
}
