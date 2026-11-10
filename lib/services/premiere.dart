import 'package:flutter/foundation.dart';

/// Premiere mode (docs/plans/studio-modes.md, phases 6-8): the film, its
/// trailer and the filmmaker's choices. One `event_films` row per event,
/// written by the `premiere` function; the host reads their own row.
/// Mirrors supabase/functions/_shared/premiere.ts.

enum MediaStatus {
  none,
  uploading,
  processing,
  ready,
  error;

  static MediaStatus fromWire(Object? v) =>
      values.firstWhere((s) => s.name == v, orElse: () => none);

  bool get busy => this == uploading || this == processing;
}

enum FilmKind { film, trailer }

enum FilmRating {
  g('G'),
  pg('PG'),
  pg13('PG-13'),
  r('R'),
  nc17('NC-17'),
  nr('NR', 'Not rated'),
  adult('18+', '18+ (age check)');

  const FilmRating(this.wire, [String? label]) : label = label ?? wire;
  final String wire;
  final String label;

  static FilmRating? fromWire(Object? v) =>
      values.where((r) => r.wire == v).firstOrNull;
}

enum ReplayPolicy {
  none('none', 'No replay'),
  day('24h', '24 hours'),
  twoDays('48h', '48 hours'),
  week('7d', '7 days'),
  forever('forever', 'Until I delete it');

  const ReplayPolicy(this.wire, this.label);
  final String wire;
  final String label;

  static ReplayPolicy fromWire(Object? v) =>
      values.firstWhere((p) => p.wire == v, orElse: () => none);
}

enum ChatPolicy {
  open('open', 'Open chat'),
  reactions('reactions', 'Reactions only'),
  slow('slow', 'Slow mode');

  const ChatPolicy(this.wire, this.label);
  final String wire;
  final String label;

  static ChatPolicy fromWire(Object? v) =>
      values.firstWhere((p) => p.wire == v, orElse: () => open);
}

@immutable
class FilmCaption {
  const FilmCaption(this.lang, this.label);
  final String lang;
  final String label;
}

/// Caption languages offered in the picker.
const kCaptionLanguages = <String, String>{
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'zh': 'Chinese',
  'ar': 'Arabic',
  'hi': 'Hindi',
};

/// One row of `event_films`.
@immutable
class EventFilm {
  const EventFilm({
    required this.eventId,
    this.filmStatus = MediaStatus.none,
    this.filmError,
    this.filmName,
    this.filmBytes,
    this.filmDuration,
    this.trailerStatus = MediaStatus.none,
    this.trailerError,
    this.trailerDuration,
    this.captions = const [],
    this.posterUrl,
    this.rating,
    this.contentWarning,
    this.replay = ReplayPolicy.none,
    this.chat = ChatPolicy.open,
    this.rightsConfirmedAt,
    this.deleteAfter,
    this.askRating = false,
  });

  factory EventFilm.empty(String eventId) => EventFilm(eventId: eventId);

  factory EventFilm.fromRow(Map<String, dynamic> r) {
    Duration? secs(Object? v) =>
        v is num && v > 0 ? Duration(milliseconds: (v * 1000).round()) : null;
    DateTime? at(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return EventFilm(
      eventId: r['event_id'] as String,
      filmStatus: MediaStatus.fromWire(r['film_status']),
      filmError: r['film_error'] as String?,
      filmName: r['film_name'] as String?,
      filmBytes: (r['film_bytes'] as num?)?.toInt(),
      filmDuration: secs(r['film_duration_s']),
      trailerStatus: MediaStatus.fromWire(r['trailer_status']),
      trailerError: r['trailer_error'] as String?,
      trailerDuration: secs(r['trailer_duration_s']),
      captions: [
        for (final c in (r['captions'] as List?) ?? const [])
          if (c is Map && c['lang'] is String)
            FilmCaption(c['lang'] as String, '${c['label'] ?? c['lang']}'),
      ],
      posterUrl: r['poster_url'] as String?,
      rating: FilmRating.fromWire(r['rating']),
      contentWarning: r['content_warning'] as String?,
      replay: ReplayPolicy.fromWire(r['replay_policy']),
      chat: ChatPolicy.fromWire(r['chat_policy']),
      rightsConfirmedAt: at(r['rights_confirmed_at']),
      deleteAfter: at(r['delete_after']),
      askRating: r['ask_rating'] == true,
    );
  }

  final String eventId;
  final MediaStatus filmStatus;
  final String? filmError;
  final String? filmName;
  final int? filmBytes;
  final Duration? filmDuration;
  final MediaStatus trailerStatus;
  final String? trailerError;
  final Duration? trailerDuration;
  final List<FilmCaption> captions;
  final String? posterUrl;
  final FilmRating? rating;
  final String? contentWarning;
  final ReplayPolicy replay;
  final ChatPolicy chat;
  final DateTime? rightsConfirmedAt;
  final DateTime? deleteAfter;

  /// The closing slate asks viewers to rate the film.
  final bool askRating;

  MediaStatus statusOf(FilmKind k) =>
      k == FilmKind.film ? filmStatus : trailerStatus;
  String? errorOf(FilmKind k) => k == FilmKind.film ? filmError : trailerError;
  Duration? durationOf(FilmKind k) =>
      k == FilmKind.film ? filmDuration : trailerDuration;

  List<ReadyItem> get checklist => [
    ReadyItem(
      'Film uploaded and processed',
      done: filmStatus == MediaStatus.ready,
      required: true,
    ),
    ReadyItem('Rating chosen', done: rating != null, required: true),
    ReadyItem(
      'Rights confirmed',
      done: rightsConfirmedAt != null,
      required: true,
    ),
    ReadyItem('Trailer', done: trailerStatus == MediaStatus.ready),
    ReadyItem('Captions', done: captions.isNotEmpty),
    ReadyItem('Poster', done: posterUrl != null),
  ];

  bool get isReady => checklist.every((i) => i.done || !i.required);
}

@immutable
class ReadyItem {
  const ReadyItem(this.label, {required this.done, this.required = false});
  final String label;
  final bool done;
  final bool required;
}

/// SubRip → WebVTT (Stream takes WebVTT). WebVTT passes through untouched.
String toWebVtt(String text) {
  var s = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (s.startsWith('﻿')) s = s.substring(1);
  if (s.trimLeft().startsWith('WEBVTT')) return s;
  final time = RegExp(r'(\d{1,2}:\d{2}:\d{2}),(\d{3})');
  final lines = s
      .split('\n')
      .map(
        (l) => l.contains('-->')
            ? l.replaceAllMapped(time, (m) => '${m[1]}.${m[2]}')
            : l,
      )
      .join('\n');
  return 'WEBVTT\n\n${lines.trim()}\n';
}

/// "1:42:05" / "12:04" for a film length.
String formatFilmLength(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// "1.4 GB" / "640 MB".
String formatBytes(int bytes) {
  const gb = 1024 * 1024 * 1024, mb = 1024 * 1024;
  return bytes >= gb
      ? '${(bytes / gb).toStringAsFixed(1)} GB'
      : '${(bytes / mb).toStringAsFixed(bytes >= 10 * mb ? 0 : 1)} MB';
}

/// A viewer's signed film stream (playback-token).
@immutable
class FilmPlayback {
  const FilmPlayback({
    required this.url,
    required this.expiresAt,
    this.captions = const [],
    this.rating,
    this.contentWarning,
    this.askRating = false,
    this.chatPolicy = ChatPolicy.open,
  });

  factory FilmPlayback.fromJson(Map d) => FilmPlayback(
    url: Uri.parse(d['url'] as String),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      (d['expiresAt'] as num?)?.toInt() ?? 0,
    ),
    captions: [
      for (final c in (d['captions'] as List?) ?? const [])
        if (c is Map && c['url'] is String && c['lang'] is String)
          FilmCaptionTrack(
            c['lang'] as String,
            '${c['label'] ?? c['lang']}',
            Uri.parse(c['url'] as String),
          ),
    ],
    rating: FilmRating.fromWire(d['rating']),
    contentWarning: d['contentWarning'] as String?,
    askRating: d['askRating'] == true,
    chatPolicy: ChatPolicy.fromWire(d['chatPolicy']),
  );

  final Uri url;
  final DateTime expiresAt;
  final List<FilmCaptionTrack> captions;
  final FilmRating? rating;
  final String? contentWarning;
  final bool askRating;
  final ChatPolicy chatPolicy;
}

@immutable
class FilmCaptionTrack {
  const FilmCaptionTrack(this.lang, this.label, this.url);
  final String lang;
  final String label;
  final Uri url;
}

/// Why playback-token said no. [age] means the film is 18+ and the account
/// doesn't show the viewer is an adult.
class FilmRefused implements Exception {
  const FilmRefused(this.message, {this.age = false, this.rating});

  factory FilmRefused.fromJson(Map d) => FilmRefused(
    d['error']?.toString() ?? 'The film can’t play right now.',
    age: d['code'] == 'age',
    rating: FilmRating.fromWire(d['rating']),
  );

  final String message;
  final bool age;
  final FilmRating? rating;

  @override
  String toString() => message;
}
