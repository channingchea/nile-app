// Premiere (studio modes phase 6): the film row, the readiness checklist,
// caption conversion, and the resumable uploader against a fake tus server.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nile_app/services/premiere.dart';
import 'package:nile_app/services/tus_upload.dart';
import 'package:nile_app/widgets/premiere_checklist.dart';

void main() {
  group('EventFilm', () {
    test('parses a row; defaults for missing fields', () {
      final f = EventFilm.fromRow({
        'event_id': 'e1',
        'film_status': 'ready',
        'film_duration_s': 5400.5,
        'film_bytes': 1073741824,
        'trailer_status': 'processing',
        'captions': [
          {'lang': 'en', 'label': 'English'},
          {'nope': 1},
        ],
        'rating': 'PG-13',
        'replay_policy': '48h',
        'chat_policy': 'reactions',
        'rights_confirmed_at': '2026-11-02T10:00:00Z',
      });
      expect(f.filmStatus, MediaStatus.ready);
      expect(f.filmDuration, const Duration(milliseconds: 5400500));
      expect(f.trailerStatus.busy, isTrue);
      expect(f.captions.single.label, 'English');
      expect(f.rating, FilmRating.pg13);
      expect(f.replay, ReplayPolicy.twoDays);
      expect(f.chat, ChatPolicy.reactions);
      final empty = EventFilm.fromRow({'event_id': 'e2', 'rating': 'X'});
      expect(empty.filmStatus, MediaStatus.none);
      expect(empty.rating, isNull);
      expect(empty.replay, ReplayPolicy.none);
    });

    test('ready needs the film, a rating and rights; extras are optional', () {
      final base = EventFilm.fromRow({
        'event_id': 'e',
        'film_status': 'ready',
        'rating': 'R',
      });
      expect(base.isReady, isFalse);
      final ok = EventFilm.fromRow({
        'event_id': 'e',
        'film_status': 'ready',
        'rating': 'R',
        'rights_confirmed_at': '2026-11-02T00:00:00Z',
      });
      expect(ok.isReady, isTrue);
      expect(ok.checklist.where((i) => !i.required && !i.done).length, 3);
    });
  });

  test('SubRip becomes WebVTT; WebVTT passes through', () {
    const srt = '﻿1\r\n00:00:01,500 --> 00:00:03,000\r\nHello, 1,000 times\r\n';
    expect(
      toWebVtt(srt),
      'WEBVTT\n\n1\n00:00:01.500 --> 00:00:03.000\nHello, 1,000 times\n',
    );
    const vtt = 'WEBVTT\n\n00:01.000 --> 00:02.000\nHi';
    expect(toWebVtt(vtt), vtt);
  });

  test('lengths and sizes', () {
    expect(
      formatFilmLength(const Duration(hours: 1, minutes: 2, seconds: 5)),
      '1:02:05',
    );
    expect(formatFilmLength(const Duration(minutes: 12, seconds: 4)), '12:04');
    expect(formatBytes(1610612736), '1.5 GB');
    expect(formatBytes(640 * 1024 * 1024), '640 MB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
  });

  group('TusUpload', () {
    late Directory dir;
    late File file;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tus');
      file = File('${dir.path}/film.bin');
      await file.writeAsBytes(Uint8List(TusUpload.chunkBytes + 1000));
    });
    tearDown(() => dir.delete(recursive: true));

    test(
      'resumes from the server offset and sends the rest in chunks',
      () async {
        var serverOffset = 1000;
        final patches = <int>[];
        final client = MockClient((req) async {
          if (req.method == 'HEAD') {
            return http.Response(
              '',
              200,
              headers: {'upload-offset': '$serverOffset'},
            );
          }
          expect(req.headers['Upload-Offset'], '$serverOffset');
          expect(req.headers['Tus-Resumable'], '1.0.0');
          patches.add(req.bodyBytes.length);
          serverOffset += req.bodyBytes.length;
          return http.Response(
            '',
            204,
            headers: {'upload-offset': '$serverOffset'},
          );
        });
        final seen = <int>[];
        await TusUpload(
          file: file,
          uploadUrl: Uri.parse('https://up/x'),
          client: client,
        ).run((sent, total) => seen.add(sent));
        expect(patches, [TusUpload.chunkBytes]); // 1000 already there
        expect(seen.last, TusUpload.chunkBytes + 1000);
      },
    );

    test('an expired URL stops with TusExpired', () async {
      final client = MockClient((_) async => http.Response('', 404));
      expect(
        TusUpload(
          file: file,
          uploadUrl: Uri.parse('https://up/x'),
          client: client,
        ).run((_, _) {}),
        throwsA(isA<TusExpired>()),
      );
    });
  });

  testWidgets('checklist shows what is done and links to settings', (t) async {
    var opened = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiereChecklist(
            film: EventFilm.fromRow({'event_id': 'e', 'rating': 'G'}),
            onOpen: () => opened++,
          ),
        ),
      ),
    );
    expect(find.text('Get your premiere ready'), findsOneWidget);
    expect(find.text('Optional'), findsNWidgets(3));
    await t.tap(find.text('Upload and set up film'));
    expect(opened, 1);
  });
}
