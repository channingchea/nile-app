import 'net.dart';
import 'studio_layouts.dart';
import 'supabase_client.dart';

/// The host's saved layouts (`studio_layouts`, owner-only RLS, 100 max).
class LayoutsService {
  static const _table = 'studio_layouts';
  static const _cols = 'id, name, payload, template, sort, updated_at';

  static Future<List<StudioLayout>> list() => guard(() async {
    final rows = await supabase
        .from(_table)
        .select(_cols)
        .order('sort')
        .order('created_at');
    return [
      for (final r in rows as List)
        StudioLayout.fromRow(Map<String, dynamic>.from(r as Map)),
    ];
  });

  /// Save [layout] as a new library item (its id is ignored). Throws
  /// [ArgumentError] with a user-facing message when it can't be saved.
  static Future<StudioLayout> create(StudioLayout layout, {String? template}) {
    _check(layout);
    return guard(() async {
      final row = await supabase
          .from(_table)
          .insert({
            'owner_id': supabase.auth.currentUser!.id,
            'name': layout.name.trim(),
            'payload': layout.payload,
            'template': template ?? layout.template,
            'sort': layout.sort,
          })
          .select(_cols)
          .single();
      return StudioLayout.fromRow(row);
    });
  }

  /// Save name and contents. Returns it with the new [StudioLayout.updatedAt].
  static Future<StudioLayout> update(StudioLayout layout) {
    _check(layout);
    return guard(() async {
      final row = await supabase
          .from(_table)
          .update({'name': layout.name.trim(), 'payload': layout.payload})
          .eq('id', layout.id)
          .select(_cols)
          .single();
      return StudioLayout.fromRow(row);
    });
  }

  static Future<StudioLayout> rename(StudioLayout layout, String name) =>
      update(layout.copyWith(name: name));

  /// A copy at the end of the library, named "… copy".
  static Future<StudioLayout> duplicate(StudioLayout layout, {int? sort}) {
    final base = layout.name.trim();
    final name = base.length > 55 ? base.substring(0, 55) : base;
    return create(
      layout.copyWith(name: '$name copy', sort: sort ?? layout.sort + 1),
    );
  }

  static Future<void> delete(StudioLayout layout) =>
      guard(() => supabase.from(_table).delete().eq('id', layout.id));

  /// Persist a new order: each item's index becomes its sort.
  static Future<void> reorder(List<StudioLayout> ordered) => guard(
    () => Future.wait([
      for (var i = 0; i < ordered.length; i++)
        if (ordered[i].sort != i)
          supabase.from(_table).update({'sort': i}).eq('id', ordered[i].id),
    ]),
  );

  static void _check(StudioLayout layout) {
    final error = layout.error;
    if (error != null) throw ArgumentError(error);
  }
}
