import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// The AppKit surface the Mac build needs and no plugin owns: the window title,
/// the Dock badge, showing and hiding the window, and the login item.
///
/// Implemented on the `nile/macos` channel in `MainFlutterWindow.swift` rather
/// than by pulling in `window_manager` — Phase 5b already did the window sizing
/// natively, and everything here is a handful of lines of AppKit against APIs
/// that plugin does not expose anyway (`NSApp.dockTile`, `SMAppService`).
///
/// Every call is a no-op off macOS, so callers do not have to guard.
class MacHost {
  MacHost._();

  static const _channel = MethodChannel('nile/macos');

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Hot reload against a binary built before the channel existed.
      return null;
    }
  }

  static Future<void> setWindowTitle(String title) =>
      _invoke<void>('setWindowTitle', title);

  /// Pass an empty string to clear the badge.
  static Future<void> setDockBadge(String label) =>
      _invoke<void>('setDockBadge', label);

  /// Brings the window back after [hideWindow] — or after the red button, which
  /// hides rather than closes.
  static Future<void> showWindow() => _invoke<void>('showWindow');

  static Future<void> hideWindow() => _invoke<void>('hideWindow');

  static Future<void> quit() => _invoke<void>('quit');

  /// `true`/`false` when the OS can answer, `null` on macOS 12 — `SMAppService`
  /// is macOS 13+ and the deployment target is 12.0. Settings treats `null` as
  /// "hide the row" rather than showing a switch that cannot move.
  static Future<bool?> launchAtLoginEnabled() =>
      _invoke<bool>('launchAtLoginState');

  /// Returns the state actually in force afterwards, which is not always what
  /// was asked for — the user can revoke a login item in System Settings.
  static Future<bool?> setLaunchAtLogin(bool enabled) =>
      _invoke<bool>('setLaunchAtLogin', enabled);
}
