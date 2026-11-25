import 'supabase_client.dart';

/// A canned line the host sends from the Studio's ⚡ menu
/// (`chat_quick_messages`, owner-only RLS, migration 0133).
class QuickMessage {
  const QuickMessage({required this.id, required this.body, this.sort = 0});

  factory QuickMessage.fromRow(Map<String, dynamic> r) => QuickMessage(
    id: r['id'] as String,
    body: r['body'] as String,
    sort: (r['sort'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String body;
  final int sort;

  static const maxLength = 500;
}

/// The host's saved quick messages and blocked words. Both belong to the
/// account, not the show, so they carry over from one event to the next.
class ChatToolsService {
  static const _quick = 'chat_quick_messages';
  static const _terms = 'chat_blocked_terms';

  static String get _uid => supabase.auth.currentUser!.id;

  static Future<List<QuickMessage>> quickMessages() async {
    final rows = await supabase
        .from(_quick)
        .select('id, body, sort')
        .order('sort')
        .order('created_at');
    return [
      for (final r in rows as List)
        QuickMessage.fromRow(Map<String, dynamic>.from(r as Map)),
    ];
  }

  static Future<QuickMessage> addQuickMessage(String body, {int sort = 0}) async {
    final row = await supabase
        .from(_quick)
        .insert({'owner_id': _uid, 'body': body.trim(), 'sort': sort})
        .select('id, body, sort')
        .single();
    return QuickMessage.fromRow(row);
  }

  static Future<void> updateQuickMessage(String id, String body) =>
      supabase.from(_quick).update({'body': body.trim()}).eq('id', id);

  static Future<void> deleteQuickMessage(String id) =>
      supabase.from(_quick).delete().eq('id', id);

  /// Persist a new order: each item's index becomes its sort.
  static Future<void> reorderQuickMessages(List<QuickMessage> ordered) =>
      Future.wait([
        for (var i = 0; i < ordered.length; i++)
          if (ordered[i].sort != i)
            supabase.from(_quick).update({'sort': i}).eq('id', ordered[i].id),
      ]);

  /// Blocked words and phrases, lower-cased, alphabetical.
  static Future<List<String>> blockedTerms() async {
    final rows = await supabase.from(_terms).select('term').order('term');
    return [for (final r in rows as List) (r as Map)['term'] as String];
  }

  /// Normalise a term the way the server matches it: trimmed, lower-case,
  /// single spaces. Null when there is nothing left (or it is too long).
  static String? cleanTerm(String raw) {
    final t = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return t.isEmpty || t.length > 60 ? null : t;
  }

  static Future<void> addBlockedTerm(String term) async {
    final t = cleanTerm(term);
    if (t == null) return;
    await supabase
        .from(_terms)
        .upsert({'owner_id': _uid, 'term': t}, ignoreDuplicates: true);
  }

  static Future<void> removeBlockedTerm(String term) =>
      supabase.from(_terms).delete().eq('owner_id', _uid).eq('term', term);
}
