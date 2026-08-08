import 'dart:io' show Platform;

import 'supabase_client.dart';

/// Persists the current device's FCM token to the `device_tokens` table so the
/// send-push Edge Function (phase 20) can reach this device. RLS scopes every
/// row to the owning user.
class DeviceTokenService {
  /// Which value goes in `device_tokens.platform`. The column's check
  /// constraint accepts exactly these three (migration 0083).
  static String get _platform {
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    return 'android';
  }

  /// Upsert the token for the signed-in user. Idempotent: `token` is unique, so
  /// re-registering the same token just refreshes ownership / last_seen_at.
  static Future<void> register(String token) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    await supabase.from('device_tokens').upsert({
      'user_id': uid,
      'token': token,
      'platform': _platform,
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }

  /// Remove this device's token on sign-out so a signed-out device stops
  /// receiving the previous user's pushes.
  static Future<void> unregister(String token) async {
    await supabase.from('device_tokens').delete().eq('token', token);
  }
}
