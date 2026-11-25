import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_gate.dart';
import 'mac_host.dart';
import 'message_service.dart';
import 'notification_service.dart';

/// The two unread counts the desktop chrome shows, in one place.
///
/// The nav rail used to own this poll. It still shows the numbers, but it is no
/// longer the only thing that wants them: on macOS the Dock badge needs the
/// same figures while the window is closed and no rail exists at all. One timer
/// with a consumer count beats two timers racing each other to the same two
/// queries — and it means opening Messages can clear the Dock badge as well as
/// the rail pill, without either knowing about the other.
class NileBadges {
  NileBadges._();

  static const _interval = Duration(seconds: 60);

  static final ValueNotifier<int> notifications = ValueNotifier<int>(0);
  static final ValueNotifier<int> messages = ValueNotifier<int>(0);

  static Timer? _timer;
  static int _consumers = 0;

  /// Start (or join) the poll. Every caller must pair this with [release].
  static void listen() {
    if (++_consumers > 1) return;
    _timer = Timer.periodic(_interval, (_) => refresh());
    refresh();
  }

  static void release() {
    if (_consumers == 0) return;
    if (--_consumers > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  /// Both counts, fetched independently: a failure on one must not blank the
  /// other, and neither is worth surfacing to the user.
  static Future<void> refresh() async {
    try {
      notifications.value = await NotificationService.unreadCount();
    } catch (_) {
      // A failed badge count is not worth surfacing.
    }
    try {
      messages.value = await MessageService.unreadTotal();
    } catch (_) {
      // As above.
    }
  }

  /// Opening either list clears it. Reflected immediately rather than waiting
  /// up to a minute for the poll to catch up.
  static void clearNotifications() => notifications.value = 0;

  static void clearMessages() => messages.value = 0;

  /// Whether the shared timer is running. The only externally visible trace of
  /// the consumer count, and the thing a leaked rail would get wrong.
  @visibleForTesting
  static bool get isPolling => _timer != null;

  @visibleForTesting
  static void resetForTesting() {
    _timer?.cancel();
    _timer = null;
    _consumers = 0;
    notifications.value = 0;
    messages.value = 0;
  }
}

/// Mirrors [NileBadges] onto the Dock icon.
///
/// One number, not two: the Dock badge is a single label, and "you have things
/// waiting" is all it can usefully say. Tapping through to which list is what
/// the app itself is for.
class NileDockBadge {
  NileDockBadge._();

  static bool _started = false;
  static bool _polling = false;

  static void start() {
    if (_started || !MacHost.supported) return;
    _started = true;
    NileBadges.notifications.addListener(_sync);
    NileBadges.messages.addListener(_sync);
    AuthGate.instance.addListener(_onAuth);
    _onAuth();
  }

  /// Only poll while there is an account to poll for. Both queries would fail
  /// signed out anyway, and a badge left sitting on the Dock after sign-out is
  /// worse than no badge — it counts someone else's mail.
  static void _onAuth() {
    final signedIn = AuthGate.instance.isSignedIn;
    if (signedIn == _polling) return;
    _polling = signedIn;
    if (signedIn) {
      NileBadges.listen();
    } else {
      NileBadges.release();
      NileBadges.clearNotifications();
      NileBadges.clearMessages();
    }
    _sync();
  }

  static void _sync() {
    final total = NileBadges.notifications.value + NileBadges.messages.value;
    // Past 99 the badge is a smudge either way, and the exact number stops
    // meaning anything.
    MacHost.setDockBadge(
      total == 0
          ? ''
          : total > 99
          ? '99+'
          : '$total',
    );
  }
}
