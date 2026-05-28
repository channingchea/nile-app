import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_service.dart';
import 'supabase_client.dart';

class SearchService {
  static const int _limit = 20;

  /// Full-text search on username and display_name (case-insensitive).
  /// Excludes the signed-in user. Returns up to [_limit] profiles.
  static Future<List<UserProfile>> searchUsers(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final myId = supabase.auth.currentUser?.id;
    final pattern = '%$q%';

    var req = supabase
        .from('profiles')
        .select()
        .or('username.ilike.$pattern,display_name.ilike.$pattern');

    final rows = await (myId != null
        ? req.neq('id', myId).order('follower_count', ascending: false).limit(_limit)
        : req.order('follower_count', ascending: false).limit(_limit));

    return (rows as List).map((r) => UserProfile.fromMap(r)).toList();
  }

  /// Returns up to [_limit] suggested creators ordered by follower count.
  /// Excludes the signed-in user.
  static Future<List<UserProfile>> suggestedUsers() async {
    final myId = supabase.auth.currentUser?.id;

    var req = supabase.from('profiles').select();

    final rows = await (myId != null
        ? req.neq('id', myId).order('follower_count', ascending: false).limit(_limit)
        : req.order('follower_count', ascending: false).limit(_limit));

    return (rows as List).map((r) => UserProfile.fromMap(r)).toList();
  }
}
