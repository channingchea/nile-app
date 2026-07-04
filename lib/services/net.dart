import 'dart:async';

import 'app_error.dart';

/// Default ceiling for a network round-trip. Past this we assume the request is
/// stuck (dead socket, captive portal) rather than merely slow, and surface a
/// retryable [AppError] instead of spinning forever.
const Duration kNetTimeout = Duration(seconds: 15);

/// Runs [op] with a [timeout] and normalizes any failure into an [AppError].
///
/// Wrap Supabase/network calls at the service layer so callers get one error
/// type to reason about and never hang on a silently-dropped connection:
///
/// ```dart
/// static Future<List<X>> getX() => guard(() async {
///   final rows = await supabase.from('x').select();
///   return rows.map(...).toList();
/// });
/// ```
Future<T> guard<T>(
  Future<T> Function() op, {
  Duration timeout = kNetTimeout,
}) async {
  try {
    return await op().timeout(timeout);
  } catch (e) {
    throw AppError.from(e);
  }
}
