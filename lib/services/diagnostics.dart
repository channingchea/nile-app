import 'dart:io' show Platform;
import 'dart:ui' show Size;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'connectivity_service.dart';
import 'supabase_client.dart';

/// The build/device facts attached to every bug report.
///
/// Deliberately boring: nothing here identifies the user beyond the id we
/// already hold, and [describe] renders the exact same map for the reporter to
/// read before they submit — no silent collection.
class Diagnostics {
  Diagnostics._();

  static PackageInfo? _package;
  static String? _device;

  static Future<Map<String, dynamic>> collect({Size? screenSize}) async {
    final pkg = _package ??= await PackageInfo.fromPlatform();
    return {
      'app_version': pkg.version,
      'build_number': pkg.buildNumber,
      'platform': kIsWeb ? 'web' : Platform.operatingSystem,
      if (!kIsWeb) 'os_version': Platform.operatingSystemVersion,
      'device': await _deviceModel(),
      'locale': kIsWeb ? '' : Platform.localeName,
      if (screenSize != null)
        'screen': '${screenSize.width.round()}x${screenSize.height.round()}',
      'online': ConnectivityService.instance.online.value,
      'user_id': supabase.auth.currentUser?.id,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// "only happens on a Pixel 6a" is the single most useful line in a bug
  /// report, so it's worth the plugin call. Cached — the model never changes.
  static Future<String> _deviceModel() async {
    if (_device != null) return _device!;
    try {
      final info = DeviceInfoPlugin();
      _device = switch (defaultTargetPlatform) {
        TargetPlatform.android => await info.androidInfo.then(
            (a) => '${a.manufacturer} ${a.model}'),
        TargetPlatform.iOS => await info.iosInfo.then((i) => i.utsname.machine),
        TargetPlatform.macOS => await info.macOsInfo.then((m) => m.model),
        _ => 'unknown',
      };
    } catch (_) {
      _device = 'unknown';
    }
    return _device!;
  }

  /// Human-readable version of [collect], shown in the form's disclosure row.
  static List<({String label, String value})> describe(
    Map<String, dynamic> d,
  ) {
    const labels = {
      'app_version': 'App version',
      'build_number': 'Build',
      'platform': 'Platform',
      'os_version': 'OS',
      'device': 'Device',
      'locale': 'Language',
      'screen': 'Screen',
      'online': 'Network',
      'user_id': 'Your account id',
    };
    return [
      for (final e in labels.entries)
        if (d[e.key] != null && '${d[e.key]}'.isNotEmpty)
          (
            label: e.value,
            value: switch (e.key) {
              'online' => d[e.key] == true ? 'online' : 'offline',
              _ => '${d[e.key]}',
            },
          ),
    ];
  }
}
