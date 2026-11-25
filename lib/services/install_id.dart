import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A random identifier generated once per install and persisted from then on.
///
/// Used as the camera's LiveKit identity. That identity has to be *stable*
/// across app launches: LiveKit evicts an existing participant when a new one
/// connects under the same identity, so a host whose app crashed mid-show
/// reclaims their own slot instead of colliding with the ghost the crash left
/// behind. A fresh id per launch (what this replaces) meant the ghost still
/// counted against the event's camera limit and locked the host out of their
/// own event until LiveKit's participant timeout cleared it.
///
/// Two devices get two ids, so genuinely separate cameras are still counted
/// separately.
class InstallId {
  static const _key = 'install_id';
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || id.isEmpty) {
      id = _generate();
      await prefs.setString(_key, id);
    }
    return _cached = id;
  }

  static String _generate() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(16).toRadixString(16),
    ).join();
  }
}
