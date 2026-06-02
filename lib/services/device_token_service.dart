import 'dart:io' show Platform;

import 'supabase_client.dart';

/// Persists the current device's FCM token to the `device_tokens` table so the
/// send-push Edge Function (phase 20) can reach this device. RLS scopes every
/// row to the owning user.
class DeviceTokenService {
  /// Upsert the token for the signed-in user. Idempotent: `token` is unique, so
  /// re-registering the same token just refreshes ownership / last_seen_at.
  static Future<void> register(String token) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    await supabase.from('device_tokens').upsert({
      'user_id': uid,
      'token': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'last_seen_at': DateTime.now().toIso8601String(),
    }, onConflict: 'token');
  }

  /// Remove this device's token on sign-out so a signed-out device stops
  /// receiving the previous user's pushes.
  static Future<void> unregister(String token) async {
    await supabase.from('device_tokens').delete().eq('token', token);
  }
}
