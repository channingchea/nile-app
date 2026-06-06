import 'supabase_client.dart';

/// Account-level actions for the signed-in user.
class AccountService {
  /// Permanently deletes the current user's account and all their data via the
  /// `delete-account` Edge Function, then signs out locally. Irreversible.
  static Future<void> deleteAccount() async {
    final response = await supabase.functions.invoke('delete-account');
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Delete failed');
    }
    await supabase.auth.signOut();
  }
}
