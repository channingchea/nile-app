import 'live_elements.dart';
import 'supabase_client.dart';

/// The host's saved elements (`studio_elements`, owner-only RLS).
class ElementsService {
  static const _table = 'studio_elements';
  static const _cols = 'id, kind, name, config, style, sort';

  static Future<List<StudioElement>> list() async {
    final rows = await supabase
        .from(_table)
        .select(_cols)
        .order('sort')
        .order('created_at');
    return [
      for (final r in rows as List)
        StudioElement.fromRow(Map<String, dynamic>.from(r as Map)),
    ];
  }

  static Future<StudioElement> create({
    required String kind,
    required String name,
    required Map<String, dynamic> config,
    ElementStyle style = ElementStyle.none,
    int sort = 0,
  }) async {
    final draft = StudioElement(
      id: '',
      kind: kind,
      name: name,
      config: config,
      style: style,
    );
    final error = draft.error;
    if (error != null) throw ArgumentError(error);
    final row = await supabase
        .from(_table)
        .insert({
          'owner_id': supabase.auth.currentUser!.id,
          'kind': kind,
          'name': name.trim(),
          'config': config,
          'style': style.toJson(),
          'sort': sort,
        })
        .select(_cols)
        .single();
    return StudioElement.fromRow(row);
  }

  static Future<void> update(StudioElement e) async {
    final error = e.error;
    if (error != null) throw ArgumentError(error);
    await supabase
        .from(_table)
        .update({
          'name': e.name.trim(),
          'config': e.config,
          'style': e.style.toJson(),
        })
        .eq('id', e.id);
  }

  static Future<void> delete(StudioElement e) =>
      supabase.from(_table).delete().eq('id', e.id);
}
