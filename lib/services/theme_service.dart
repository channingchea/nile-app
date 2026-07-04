import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'supabase_client.dart';

/// App-wide theme mode (System / Light / Dark).
///
/// Persistence & reconcile rule:
/// - Local storage (shared_preferences) is the source of truth for immediate,
///   offline paint — loaded in _bootstrap() BEFORE runApp, so the first frame
///   is already in the right theme (no flash).
/// - Every user change is mirrored to profiles.theme_mode for cross-device
///   sync. A failed profile write is ignored — local still drives the UI and
///   the value is re-sent on the next change.
/// - On sign-in, the profile value is adopted ONLY when no local value exists
///   (fresh install / new device); otherwise local wins.
/// - Default for new users: Dark (the design system's native theme).
class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  static const _prefKey = 'theme_mode';

  /// Drives MaterialApp.themeMode; listen to rebuild on change.
  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.dark);

  SharedPreferences? _prefs;
  bool _hasLocal = false;

  /// Load the saved mode. Call before runApp; defaults to Dark on any error.
  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final saved = _prefs?.getString(_prefKey);
      _hasLocal = saved != null;
      mode.value = _parse(saved) ?? ThemeMode.dark;
    } catch (_) {
      // shared_preferences unavailable — keep the Dark default.
    }
    _applyPalette(rebuild: false);
  }

  /// User-initiated change: apply instantly, persist local + profile.
  Future<void> setMode(ThemeMode m) async {
    _hasLocal = true;
    if (mode.value != m) {
      mode.value = m;
      _applyPalette();
    }
    try {
      await _prefs?.setString(_prefKey, m.name);
    } catch (_) {}
    _syncProfile(m);
  }

  /// Adopt profiles.theme_mode on sign-in when no local choice exists yet.
  Future<void> onSignIn() async {
    if (_hasLocal) return;
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return;
      final row = await supabase
          .from('profiles')
          .select('theme_mode')
          .eq('id', uid)
          .maybeSingle();
      final m = _parse(row?['theme_mode'] as String?);
      // Re-check _hasLocal: the user may have picked a mode mid-fetch.
      if (m == null || _hasLocal) return;
      _hasLocal = true;
      await _prefs?.setString(_prefKey, m.name);
      if (mode.value != m) {
        mode.value = m;
        _applyPalette();
      }
    } catch (_) {
      // Offline or missing column — keep local/default.
    }
  }

  /// Call from didChangePlatformBrightness so System mode tracks the OS live.
  void onPlatformBrightnessChanged() {
    if (mode.value == ThemeMode.system) _applyPalette();
  }

  Brightness get _effectiveBrightness => switch (mode.value) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };

  void _applyPalette({bool rebuild = true}) {
    NileColors.palette = NilePalette.of(_effectiveBrightness);
    if (rebuild) _rebuildApp();
  }

  /// Mark every element dirty so builds re-read the new palette everywhere,
  /// including const-constructed subtrees Flutter would otherwise skip.
  /// Preserves all state and the navigation stack (nothing is re-inflated).
  void _rebuildApp() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    visit(root);
  }

  void _syncProfile(ThemeMode m) async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return;
      await supabase
          .from('profiles')
          .update({'theme_mode': m.name})
          .eq('id', uid);
    } catch (_) {
      // Non-blocking — local persisted; re-sent on next change.
    }
  }

  static ThemeMode? _parse(String? s) => switch (s) {
    'system' => ThemeMode.system,
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => null,
  };
}
