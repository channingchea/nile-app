import 'dart:collection';

import 'package:flutter/foundation.dart';

/// A small in-memory ring of the most recent uncaught errors, attached to bug
/// reports so a report can say what actually blew up instead of "it crashed".
///
/// Sentry hooks the same two handlers when a DSN is configured. [install]
/// CHAINS to whatever is already there rather than replacing it, so turning
/// Sentry back on doesn't silence this — and this doesn't silence Sentry.
class ErrorLog {
  ErrorLog._();

  static const int capacity = 20;
  static const int _maxChars = 1200;

  static final ListQueue<Map<String, dynamic>> _entries = ListQueue();
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;

    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exceptionAsString(), details.stack);
      prevFlutter?.call(details);
    };

    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error.toString(), stack);
      return prevPlatform?.call(error, stack) ?? false;
    };
  }

  /// Also callable directly from a `catch` that swallows an error the user
  /// would otherwise never be able to describe.
  static void record(String message, [StackTrace? stack]) {
    if (_entries.length >= capacity) _entries.removeFirst();
    _entries.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'message': _clean(message),
      if (stack != null) 'stack': _clean(stack.toString()),
    });
  }

  /// Snapshot for a report, oldest first.
  static List<Map<String, dynamic>> snapshot() => List.unmodifiable(_entries);

  static int get length => _entries.length;

  static void clear() => _entries.clear();

  /// Truncate, then scrub the shapes that carry credentials or personal data.
  /// An error string is arbitrary text — it can contain a JWT from a failed
  /// request or an email from a validation message, and this buffer is read by
  /// an admin, so it gets redacted before it ever leaves the device.
  static String _clean(String raw) {
    var s = raw.length > _maxChars ? '${raw.substring(0, _maxChars)}…' : raw;
    for (final p in _redactions) {
      s = s.replaceAll(p, '[redacted]');
    }
    return s;
  }

  static final List<RegExp> _redactions = [
    RegExp(r'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]+'), // JWT
    RegExp(r'\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{8,}\b'), // Stripe keys
    RegExp(r'\b(bearer|apikey|api_key|token|password|secret)\b\s*[:=]?\s*\S+',
        caseSensitive: false),
    RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'), // emails
  ];
}
