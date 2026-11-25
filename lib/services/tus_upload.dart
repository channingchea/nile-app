import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// The upload URL is no longer accepting bytes (expired, or deleted).
class TusExpired implements Exception {
  @override
  String toString() => 'This upload expired. Start it again.';
}

class TusCancelled implements Exception {}

/// A minimal tus 1.0 client for Cloudflare Stream's direct uploads: HEAD for
/// the offset, then PATCH the rest in chunks. Resumes from wherever the
/// server says it got to, so a dropped connection (or a relaunch with the
/// same URL) carries on instead of starting over.
class TusUpload {
  TusUpload({required this.file, required this.uploadUrl, http.Client? client})
    : _client = client ?? http.Client();

  final File file;
  final Uri uploadUrl;
  final http.Client _client;
  bool _cancelled = false;

  /// Stream wants chunks of at least 5 MiB, in multiples of 256 KiB.
  static const chunkBytes = 16 * 1024 * 1024;
  static const _headers = {'Tus-Resumable': '1.0.0'};

  void cancel() => _cancelled = true;

  /// Bytes the server already has.
  Future<int> offset() async {
    final res = await _client.head(uploadUrl, headers: _headers);
    if (res.statusCode == 404 || res.statusCode == 410) throw TusExpired();
    if (res.statusCode >= 400) {
      throw HttpException('Upload check failed (${res.statusCode})');
    }
    return int.tryParse(res.headers['upload-offset'] ?? '') ?? 0;
  }

  /// Sends the file from the server's offset to the end. [onProgress] gets
  /// (bytes sent, total). Retries a failed chunk up to 5 times, re-reading
  /// the offset each time.
  Future<void> run(void Function(int sent, int total) onProgress) async {
    final total = await file.length();
    var off = await offset();
    onProgress(off, total);
    final raf = await file.open();
    try {
      var failures = 0;
      while (off < total) {
        if (_cancelled) throw TusCancelled();
        final n = math.min(chunkBytes, total - off);
        try {
          await raf.setPosition(off);
          final bytes = await raf.read(n);
          final res = await _client
              .patch(
                uploadUrl,
                headers: {
                  ..._headers,
                  'Upload-Offset': '$off',
                  'Content-Type': 'application/offset+octet-stream',
                },
                body: bytes,
              )
              .timeout(const Duration(minutes: 5));
          if (res.statusCode == 404 || res.statusCode == 410) {
            throw TusExpired();
          }
          if (res.statusCode == 409) {
            off = await offset(); // we were out of step; carry on from theirs
            continue;
          }
          if (res.statusCode >= 400) {
            throw HttpException('Upload failed (${res.statusCode})');
          }
          off = int.tryParse(res.headers['upload-offset'] ?? '') ?? off + n;
          failures = 0;
          onProgress(off, total);
        } on TusExpired {
          rethrow;
        } catch (_) {
          if (_cancelled) throw TusCancelled();
          if (++failures > 5) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 << failures));
          off = await offset();
        }
      }
    } finally {
      await raf.close();
    }
  }

  void close() => _client.close();
}
