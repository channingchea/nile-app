import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import 'studio_graphics.dart';
import 'supabase_client.dart';

/// The host's saved graphics library (`studio_graphics`, owner-only RLS) and
/// its images (`studio-graphics` bucket, `<uid>/…`, 2 MB, PNG/JPG/WebP).
class GraphicsService {
  static const _table = 'studio_graphics';
  static const _bucket = 'studio-graphics';
  static const maxImageBytes = 2 * 1024 * 1024;

  static Future<List<StudioGraphic>> list() async {
    final rows = await supabase
        .from(_table)
        .select('id, kind, name, payload, sort')
        .order('sort')
        .order('created_at');
    return [
      for (final r in rows as List)
        StudioGraphic.fromRow(Map<String, dynamic>.from(r as Map)),
    ];
  }

  /// Save a new graphic at the end of the library.
  static Future<StudioGraphic> create({
    required GraphicKind kind,
    required String name,
    required Map<String, dynamic> payload,
    int sort = 0,
  }) async {
    final error = StudioGraphic.validate(kind, payload);
    if (error != null) throw ArgumentError(error);
    final row = await supabase
        .from(_table)
        .insert({
          'owner_id': supabase.auth.currentUser!.id,
          'kind': kind.wire,
          'name': name.trim(),
          'payload': payload,
          'sort': sort,
        })
        .select('id, kind, name, payload, sort')
        .single();
    return StudioGraphic.fromRow(row);
  }

  static Future<void> update(StudioGraphic g) async {
    final error = StudioGraphic.validate(g.kind, g.payload);
    if (error != null) throw ArgumentError(error);
    await supabase
        .from(_table)
        .update({'name': g.name.trim(), 'payload': g.payload})
        .eq('id', g.id);
  }

  static Future<void> delete(StudioGraphic g) async {
    await supabase.from(_table).delete().eq('id', g.id);
    // The image goes with it — best effort; an orphan costs only storage.
    final path = g.payload['imagePath'] as String?;
    if (path != null && path.isNotEmpty) {
      try {
        await supabase.storage.from(_bucket).remove([path]);
      } catch (_) {}
    }
  }

  /// Persist a new order: each item's index becomes its sort.
  static Future<void> reorder(List<StudioGraphic> ordered) async {
    await Future.wait([
      for (var i = 0; i < ordered.length; i++)
        if (ordered[i].sort != i)
          supabase.from(_table).update({'sort': i}).eq('id', ordered[i].id),
    ]);
  }

  /// Pick an image and upload it under the caller's folder. Returns the
  /// storage path, or null if the picker was cancelled.
  static Future<String?> pickAndUploadImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length > maxImageBytes) {
      throw ArgumentError('Images are 2 MB at most.');
    }
    final ext = file.name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      _ => throw ArgumentError('Use a PNG, JPG or WebP image.'),
    };
    final uid = supabase.auth.currentUser!.id;
    final path = '$uid/${DateTime.now().millisecondsSinceEpoch}.$ext';
    await supabase.storage
        .from(_bucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
    return path;
  }

  static String publicUrl(String path) =>
      supabase.storage.from(_bucket).getPublicUrl(path);
}
