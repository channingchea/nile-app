import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// App-wide network reachability, exposed as a [ValueListenable] so any widget
/// can rebuild when the device goes on/offline.
///
/// This reflects the OS's view of the active network interface (wifi/cellular/
/// none), not whether Nile's servers are actually reachable — a captive portal
/// still reads as "online". It's a cheap first signal; real request failures are
/// still normalized through [AppError]. On web it maps to `navigator.onLine`.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final ValueNotifier<bool> online = ValueNotifier<bool>(true);
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// Start listening. Safe to call once at startup; repeated calls are no-ops.
  Future<void> init() async {
    if (_sub != null) return;
    final conn = Connectivity();
    _apply(await conn.checkConnectivity());
    _sub = conn.onConnectivityChanged.listen(_apply);
  }

  void _apply(List<ConnectivityResult> results) {
    online.value =
        results.isNotEmpty && !results.every((r) => r == ConnectivityResult.none);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
