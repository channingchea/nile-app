import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class Topic {
  final String id;
  final String slug;
  final String name;
  final int sortOrder;

  const Topic({
    required this.id,
    required this.slug,
    required this.name,
    required this.sortOrder,
  });

  factory Topic.fromMap(Map<String, dynamic> map) => Topic(
    id: map['id'] as String,
    slug: map['slug'] as String,
    name: map['name'] as String,
    sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
  );
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Topic taxonomy + user interests (bubble picker) + event tags.
class TopicService {
  /// Active topics in curated bubble order.
  static Future<List<Topic>> listTopics() async {
    final rows = await supabase
        .from('topics')
        .select('id, slug, name, sort_order')
        .eq('is_active', true)
        .order('sort_order', ascending: true);
    return (rows as List)
        .map((r) => Topic.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  // ─── User interests ───────────────────────────────────────────────────────

  /// The signed-in user's explicit interests as topicId → weight (1–3).
  static Future<Map<String, int>> myInterests() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return {};
    final rows = await supabase
        .from('user_topics')
        .select('topic_id, weight')
        .eq('user_id', uid)
        .eq('source', 'explicit');
    return {
      for (final r in rows as List)
        r['topic_id'] as String: (r['weight'] as num).toInt(),
    };
  }

  /// Upsert the user's interest weight for [topicId]; weight 0 deletes the row.
  static Future<void> setInterest(String topicId, int weight) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    if (weight <= 0) {
      await supabase
          .from('user_topics')
          .delete()
          .eq('user_id', uid)
          .eq('topic_id', topicId);
      return;
    }
    await supabase.from('user_topics').upsert({
      'user_id': uid,
      'topic_id': topicId,
      'weight': weight,
      'source': 'explicit',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id,topic_id');
  }

  // ─── Event tags ───────────────────────────────────────────────────────────

  /// Topic ids tagged on [eventId].
  static Future<List<String>> topicIdsForEvent(String eventId) async {
    final rows = await supabase
        .from('event_topics')
        .select('topic_id')
        .eq('event_id', eventId);
    return (rows as List).map((r) => r['topic_id'] as String).toList();
  }

  /// Replace [eventId]'s tags with [topicIds] (insert added, delete removed).
  /// RLS restricts writes to the event's host.
  static Future<void> setEventTopics(
    String eventId,
    List<String> topicIds,
  ) async {
    final current = (await topicIdsForEvent(eventId)).toSet();
    final wanted = topicIds.toSet();
    final toAdd = wanted.difference(current).toList();
    final toRemove = current.difference(wanted).toList();
    if (toAdd.isNotEmpty) {
      await supabase.from('event_topics').insert([
        for (final id in toAdd) {'event_id': eventId, 'topic_id': id},
      ]);
    }
    if (toRemove.isNotEmpty) {
      await supabase
          .from('event_topics')
          .delete()
          .eq('event_id', eventId)
          .inFilter('topic_id', toRemove);
    }
  }
}
