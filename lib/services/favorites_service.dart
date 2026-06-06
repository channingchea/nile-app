import 'profile_service.dart';
import 'supabase_client.dart';

/// The current user's personal "favorite people" list, used to quickly assign
/// camera operators without searching the whole user base each time.
class FavoritesService {
  /// Favorited profiles for the signed-in user, most-recently-added first.
  static Future<List<UserProfile>> list() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await supabase
        .from('operator_favorites')
        .select('created_at, profiles!operator_favorites_favorite_id_fkey(*)')
        .eq('user_id', uid)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => (r as Map<String, dynamic>)['profiles'])
        .whereType<Map<String, dynamic>>()
        .map(UserProfile.fromMap)
        .toList();
  }

  /// The set of favorited user ids, for marking stars in search results.
  static Future<Set<String>> idSet() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return {};
    final rows = await supabase
        .from('operator_favorites')
        .select('favorite_id')
        .eq('user_id', uid);
    return {
      for (final r in rows as List) (r as Map<String, dynamic>)['favorite_id'] as String
    };
  }

  static Future<void> add(String favoriteId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null || uid == favoriteId) return;
    await supabase
        .from('operator_favorites')
        .upsert({'user_id': uid, 'favorite_id': favoriteId});
  }

  static Future<void> remove(String favoriteId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    await supabase
        .from('operator_favorites')
        .delete()
        .eq('user_id', uid)
        .eq('favorite_id', favoriteId);
  }
}
