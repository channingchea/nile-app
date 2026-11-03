import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import 'premiere.dart';
import 'supabase_client.dart';
import 'tus_upload.dart';

/// Calls the `premiere` function and reads the host's `event_films` row.
abstract final class PremiereService {
  static Future<Map> _invoke(Map<String, dynamic> body) async {
    try {
      final res = await supabase.functions.invoke('premiere', body: body);
      final data = res.data;
      if (data is Map && data['error'] != null) {
        throw Exception(data['error'].toString());
      }
      return data as Map;
    } on FunctionException catch (e) {
      final d = e.details;
      throw Exception(
        (d is Map ? d['error']?.toString() : null) ??
            'Premiere request failed (${e.status})',
      );
    }
  }

  static EventFilm? _filmOf(Map d) => d['film'] is Map
      ? EventFilm.fromRow(Map<String, dynamic>.from(d['film'] as Map))
      : null;

  /// The host's film row (an empty one before anything is uploaded).
  static Future<EventFilm> fetch(String eventId) async {
    final row = await supabase
        .from('event_films')
        .select()
        .eq('event_id', eventId)
        .maybeSingle();
    return row == null ? EventFilm.empty(eventId) : EventFilm.fromRow(row);
  }

  /// Calls [onChange] whenever the row changes (upload done, processed, …).
  static RealtimeChannel watch(String eventId, void Function() onChange) =>
      supabase
          .channel('event_films:$eventId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'event_films',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'event_id',
              value: eventId,
            ),
            callback: (_) => onChange(),
          )
          .subscribe();

  /// Asks Stream directly about anything still processing (webhook fallback).
  static Future<EventFilm?> refresh(String eventId) async =>
      _filmOf(await _invoke({'action': 'refresh', 'eventId': eventId}));

  static Future<({Uri uploadUrl, EventFilm? film})> createUpload({
    required String eventId,
    required FilmKind kind,
    required int size,
    required String name,
    Duration? duration,
    bool replace = false,
  }) async {
    final d = await _invoke({
      'action': 'create-upload',
      'eventId': eventId,
      'kind': kind.name,
      'size': size,
      'name': name,
      if (duration != null) 'durationS': duration.inMilliseconds / 1000,
      if (replace) 'replace': true,
    });
    return (uploadUrl: Uri.parse(d['uploadUrl'] as String), film: _filmOf(d));
  }

  /// Partial: pass only what changes.
  static Future<EventFilm?> setDetails(
    String eventId, {
    FilmRating? rating,
    String? contentWarning,
    ReplayPolicy? replay,
    ChatPolicy? chat,
    String? posterUrl,
    bool clearPoster = false,
    bool? rightsConfirmed,
  }) async => _filmOf(
    await _invoke({
      'action': 'set-details',
      'eventId': eventId,
      'rating': ?rating?.wire,
      'contentWarning': ?contentWarning,
      'replayPolicy': ?replay?.wire,
      'chatPolicy': ?chat?.wire,
      if (posterUrl != null || clearPoster) 'posterUrl': posterUrl,
      'rightsConfirmed': ?rightsConfirmed,
    }),
  );

  static Future<EventFilm?> addCaptions(
    String eventId, {
    required String lang,
    required String label,
    required String text,
  }) async => _filmOf(
    await _invoke({
      'action': 'add-captions',
      'eventId': eventId,
      'lang': lang,
      'label': label,
      'vtt': toWebVtt(text),
    }),
  );

  static Future<EventFilm?> removeCaptions(String eventId, String lang) async =>
      _filmOf(
        await _invoke({
          'action': 'remove-captions',
          'eventId': eventId,
          'lang': lang,
        }),
      );

  static Future<EventFilm?> deleteMedia(String eventId, FilmKind kind) async {
    await PremiereUploads.instance.forget(eventId, kind);
    return _filmOf(
      await _invoke({
        'action': 'delete-media',
        'eventId': eventId,
        'kind': kind.name,
      }),
    );
  }

  /// A signed HLS URL for the film (host preview now; viewers in phase 7).
  static Future<Uri> filmUrl(String eventId) async => Uri.parse(
    (await _invoke({'action': 'playback-token', 'eventId': eventId}))['url']
        as String,
  );

  /// A signed HLS URL for the trailer, or null when there isn't one.
  static Future<({Uri? url, String? posterUrl})> trailer(String eventId) async {
    final d = await _invoke({'action': 'trailer-token', 'eventId': eventId});
    return (
      url: d['url'] is String ? Uri.parse(d['url'] as String) : null,
      posterUrl: d['posterUrl'] as String?,
    );
  }

  /// Stores a poster image beside the event's cover and saves its URL.
  static Future<EventFilm?> uploadPoster({
    required String eventId,
    required String slug,
    required Uint8List bytes,
  }) async {
    final path = '$slug/poster.jpg';
    await supabase.storage
        .from('events')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    final url = supabase.storage.from('events').getPublicUrl(path);
    return setDetails(
      eventId,
      posterUrl: '$url?t=${DateTime.now().millisecondsSinceEpoch}',
    );
  }
}

/// One film or trailer upload in flight (or paused).
class UploadJob {
  UploadJob(this.eventId, this.kind, this.fileName);
  final String eventId;
  final FilmKind kind;
  final String fileName;
  int sent = 0;
  int total = 0;
  bool running = false;
  bool expired = false;
  String? error;
  TusUpload? _tus;

  double get progress => total == 0 ? 0 : sent / total;
}

/// App-wide uploads, so leaving the film screen doesn't stop one. Each
/// upload's URL and file are saved, so after a crash or relaunch the host can
/// resume from where Stream says it got to (until the URL expires, 6 h).
class PremiereUploads extends ChangeNotifier {
  PremiereUploads._();
  static final instance = PremiereUploads._();

  final Map<String, UploadJob> _jobs = {};

  static String _key(String eventId, FilmKind kind) => '$eventId/${kind.name}';
  static String _prefKey(String eventId, FilmKind kind) =>
      'premiere.upload.$eventId.${kind.name}';

  UploadJob? job(String eventId, FilmKind kind) => _jobs[_key(eventId, kind)];

  /// A saved upload this device can pick up again (same file, still there).
  Future<({String path, Uri url, String name})?> resumable(
    String eventId,
    FilmKind kind,
  ) async {
    if (job(eventId, kind)?.running == true) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey(eventId, kind));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final f = File(m['path'] as String);
      if (!await f.exists() || await f.length() != m['size']) return null;
      return (
        path: f.path,
        url: Uri.parse(m['url'] as String),
        name: m['name'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// Uploads [file] as this event's film or trailer.
  Future<void> start({
    required String eventId,
    required FilmKind kind,
    required File file,
    required String name,
    bool replace = false,
  }) async {
    final j = UploadJob(eventId, kind, name)..running = true;
    _jobs[_key(eventId, kind)] = j;
    notifyListeners();
    try {
      final size = await file.length();
      j.total = size;
      final created = await PremiereService.createUpload(
        eventId: eventId,
        kind: kind,
        size: size,
        name: name,
        duration: await _durationOf(file),
        replace: replace,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey(eventId, kind),
        jsonEncode({
          'url': created.uploadUrl.toString(),
          'path': file.path,
          'size': size,
          'name': name,
        }),
      );
      await _run(j, file, created.uploadUrl);
    } catch (e) {
      _fail(j, e);
    }
  }

  /// Carries on a saved upload.
  Future<void> resume(String eventId, FilmKind kind) async {
    final saved = await resumable(eventId, kind);
    if (saved == null) return;
    final j = UploadJob(eventId, kind, saved.name)..running = true;
    _jobs[_key(eventId, kind)] = j;
    notifyListeners();
    try {
      await _run(j, File(saved.path), saved.url);
    } catch (e) {
      _fail(j, e);
    }
  }

  void cancel(String eventId, FilmKind kind) {
    job(eventId, kind)?._tus?.cancel();
  }

  /// Drops any saved upload for this slot (after a delete or a fresh start).
  Future<void> forget(String eventId, FilmKind kind) async {
    cancel(eventId, kind);
    _jobs.remove(_key(eventId, kind));
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey(eventId, kind));
    notifyListeners();
  }

  Future<void> _run(UploadJob j, File file, Uri url) async {
    final tus = TusUpload(file: file, uploadUrl: url);
    j._tus = tus;
    var lastNotify = DateTime(0);
    try {
      await tus.run((sent, total) {
        j
          ..sent = sent
          ..total = total;
        final now = DateTime.now();
        if (now.difference(lastNotify) > const Duration(milliseconds: 250) ||
            sent == total) {
          lastNotify = now;
          notifyListeners();
        }
      });
    } finally {
      tus.close();
    }
    j.running = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey(j.eventId, j.kind));
    notifyListeners();
    // Stream now processes it; the webhook updates the row. Nudge in case.
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 5),
        () => PremiereService.refresh(j.eventId).catchError((_) => null),
      ),
    );
  }

  void _fail(UploadJob j, Object e) {
    j
      ..running = false
      ..expired = e is TusExpired
      ..error = e is TusCancelled
          ? null
          : e.toString().replaceFirst('Exception: ', '');
    notifyListeners();
  }

  /// The file's running time, for Stream's storage reservation. Null when
  /// the platform can't read it quickly — the server then reserves 4 h.
  static Future<Duration?> _durationOf(File file) async {
    if (kIsWeb) return null;
    final c = VideoPlayerController.file(file);
    try {
      await c.initialize().timeout(const Duration(seconds: 10));
      final d = c.value.duration;
      return d > Duration.zero ? d : null;
    } catch (_) {
      return null;
    } finally {
      unawaited(c.dispose());
    }
  }
}
