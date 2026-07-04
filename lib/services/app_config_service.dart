import 'package:flutter/foundation.dart' show kIsWeb;
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

  const AppUpdateStatus({
    required this.blocked,
    required this.updateAvailable,
    this.message,
    this.updateUrl,
  });

  /// The all-clear: nothing to prompt.
  const AppUpdateStatus.ok()
      : blocked = false,
        updateAvailable = false,
        message = null,
        updateUrl = null;
}

/// Startup version gate. Reads the singleton `app_config` row and compares it to
/// the running build number.
///
/// Fails **open**: any error (offline, missing row, unparsable build) returns
/// [AppUpdateStatus.ok] so a config problem can never brick the app. Web is
/// never gated — it always serves the latest build on reload.
class AppConfigService {
  static Future<AppUpdateStatus> check() async {
    if (kIsWeb) return const AppUpdateStatus.ok();
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final rows = await supabase
          .from('app_config')
          .select('min_build, latest_build, update_url, message')
          .eq('id', 1)
          .limit(1)
          .timeout(kNetTimeout);
      if (rows.isEmpty) return const AppUpdateStatus.ok();
      final cfg = rows.first;
      final minBuild = (cfg['min_build'] as num?)?.toInt() ?? 0;
      final latestBuild = (cfg['latest_build'] as num?)?.toInt() ?? 0;
      return AppUpdateStatus(
        blocked: current < minBuild,
        updateAvailable: current < latestBuild,
        message: cfg['message'] as String?,
        updateUrl: cfg['update_url'] as String?,
      );
    } catch (_) {
      return const AppUpdateStatus.ok();
    }
  }
}
