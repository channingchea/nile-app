import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';
import '../widgets/empty_state.dart';

/// The coarse category of a failure, chosen so the UI can react without
/// inspecting raw exception types everywhere.
///
/// - [network]  no route to the server (offline, DNS, dropped socket) — retryable.
/// - [timeout]  the request took too long — retryable.
/// - [auth]     the session is missing/expired — route the user to sign-in.
/// - [server]   the backend rejected the request (Postgrest/HTTP 4xx/5xx).
/// - [unknown]  anything we didn't classify.
enum AppErrorKind { network, timeout, auth, server, unknown }

/// A normalized error with a user-facing [message]. Build one with
/// [AppError.from] so every layer classifies exceptions the same way, and use
/// [isRetryable] to decide whether to show a "Retry" affordance.
class AppError implements Exception {
  final AppErrorKind kind;
  final String message;
  final Object? cause;

  const AppError(this.kind, this.message, [this.cause]);

  /// True for transient failures worth offering a retry on.
  bool get isRetryable =>
      kind == AppErrorKind.network || kind == AppErrorKind.timeout;

  /// True when the session is the problem and the user should re-authenticate.
  bool get isAuth => kind == AppErrorKind.auth;

  /// Classify any thrown object into an [AppError] with a friendly message.
  /// Already-classified [AppError]s pass through untouched.
  factory AppError.from(Object error) {
    if (error is AppError) return error;
    if (error is TimeoutException) {
      return AppError(
        AppErrorKind.timeout,
        'This is taking longer than expected. Check your connection and try again.',
        error,
      );
    }
    if (error is AuthException) {
      return AppError(
        AppErrorKind.auth,
        'Your session expired. Please sign in again.',
        error,
      );
    }
    if (error is PostgrestException) {
      return AppError(
        AppErrorKind.server,
        'Something went wrong on our end. Please try again.',
        error,
      );
    }
    // ClientException (package:http) and generic connection strings surface as
    // network problems in practice.
    final s = error.toString().toLowerCase();
    if (s.contains('socketexception') ||
        s.contains('clientexception') ||
        s.contains('failed host lookup') ||
        s.contains('connection closed') ||
        s.contains('connection refused') ||
        s.contains('network is unreachable') ||
        s.contains('xmlhttprequest')) {
      return AppError(
        AppErrorKind.network,
        "Can't reach Nile. Check your connection and try again.",
        error,
      );
    }
    return AppError(AppErrorKind.unknown, 'Something went wrong.', error);
  }

  @override
  String toString() => 'AppError($kind): $message';
}

/// A ready-made error state for list/detail screens. Renders [NileEmptyState]
/// with a Retry button for transient errors and a copy that matches the
/// error's [AppError.kind].
class NileErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  const NileErrorState({super.key, required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final e = AppError.from(error);
    final showRetry = onRetry != null && e.isRetryable;
    return NileEmptyState(
      icon: e.kind == AppErrorKind.network
          ? Icons.wifi_off_rounded
          : Icons.error_outline_rounded,
      iconColor: NileColors.txtTertiary,
      title: e.kind == AppErrorKind.network ? "You're offline" : 'Something went wrong',
      body: e.message,
      actionLabel: showRetry ? 'Retry' : null,
      onAction: showRetry ? onRetry : null,
    );
  }
}
