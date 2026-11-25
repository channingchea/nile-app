import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// macOS Screen Recording (TCC) permission for screen sharing.
///
/// Screen capture is the one broadcast input macOS refuses to grant in-process.
/// `CGRequestScreenCaptureAccess` shows the system prompt once, but the grant
/// does not reach a process that is already running — the app has to be
/// relaunched before it can capture. Failing silently there reads as "screen
/// share is broken", so this asks first and explains the relaunch when the
/// answer is no.
///
/// Everywhere except macOS this is a pass-through: iOS shares through the
/// Broadcast Upload Extension and needs none of it.
class ScreenCapturePermission {
  ScreenCapturePermission._();

  /// System Settings ▸ Privacy & Security ▸ Screen Recording. The legacy
  /// `x-apple.systempreferences:` scheme is still what System Settings answers
  /// to on macOS 13+ — there is no newer replacement.
  static const _settingsPane =
      'x-apple.systempreferences:com.apple.preference.security'
      '?Privacy_ScreenCapture';

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// Whether capture is permitted, prompting the first time.
  ///
  /// The plugin exposes no preflight-only call, so this is the request path:
  /// harmless once permission exists (it returns true without a prompt), and it
  /// is only ever reached from an explicit user action.
  static Future<bool> check() async {
    if (!isSupported) return true;
    try {
      return await rtc.Helper.requestCapturePermission();
    } catch (_) {
      return false;
    }
  }

  /// Ask for permission, and on refusal explain how to grant it. Returns true
  /// only when capture may proceed right now.
  static Future<bool> ensure(BuildContext context) async {
    if (!isSupported) return true;
    final granted = await check();
    if (granted) return true;
    if (!context.mounted) return false;
    await showDeniedDialog(context);
    return false;
  }

  /// The "grant this and come back" dialog. Public because the source picker
  /// can land here too: an empty source list on macOS means the same missing
  /// permission, just discovered a step later.
  static Future<void> showDeniedDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text(
          'Screen Recording permission needed',
          style: NileTextStyles.headingSm(),
        ),
        content: Text(
          'macOS has to allow Nile to capture the screen before you can share '
          'it.\n\nTurn on Nile under Privacy & Security ▸ Screen Recording, '
          'then quit Nile and open it again — macOS only applies the change to '
          'a fresh launch.',
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Not now',
              style: NileTextStyles.labelMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              openSettings();
            },
            child: Text(
              'Open System Settings',
              style: NileTextStyles.labelMd().copyWith(color: NileColors.volt),
            ),
          ),
        ],
      ),
    );
  }

  /// Best-effort deep link to the Screen Recording pane.
  static Future<void> openSettings() async {
    try {
      await launchUrl(
        Uri.parse(_settingsPane),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Nothing useful to do — the dialog already spelled out the path.
    }
  }
}
