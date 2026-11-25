import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:tray_manager/tray_manager.dart';

import '../router.dart';
import 'auth_gate.dart';
import 'event_service.dart';
import 'mac_host.dart';

/// The menu-bar item: who is live right now, one click away, whether or not
/// Nile has a window open.
///
/// It is the payoff for the app outliving its window — you close Nile, keep
/// working, and the mark in the menu bar turns coral when a show starts.
class MacTray {
  MacTray._();

  /// Long enough not to be chatty, short enough that "who's live" is not stale
  /// by the time you look. Matches the context rail's own cadence.
  static const _interval = Duration(seconds: 90);

  /// Template: AppKit tints it for the current menu bar, light or dark.
  static const _idleIcon = 'assets/images/tray_icon.png';

  /// Not a template, so the coral survives — the whole point is that it reads
  /// as different at a glance.
  static const _liveIcon = 'assets/images/tray_icon_live.png';

  static final _listener = _MacTrayListener();

  static bool _started = false;
  static var _live = <_LiveHost>[];
  static bool? _showingLive;

  static Future<void> start() async {
    if (_started || !MacHost.supported) return;
    _started = true;

    try {
      trayManager.addListener(_listener);
      await _setIcon(live: false);
      await trayManager.setToolTip('Nile');
      await _rebuildMenu();
    } on MissingPluginException {
      // No tray plugin on the other end — a widget test, or a build made before
      // the dependency landed. Stand down rather than taking startup with it.
      trayManager.removeListener(_listener);
      _started = false;
      _showingLive = null;
      return;
    }

    // Signing out has to empty the menu — a stranger at the same Mac should not
    // be able to read who the last user followed out of the menu bar.
    AuthGate.instance.addListener(refresh);
    // Not held: the menu bar item lives as long as the process does, and there
    // is no point in the app's life where it should stop reporting.
    Timer.periodic(_interval, (_) => refresh());
    await refresh();
  }

  static Future<void> refresh() async {
    if (!_started) return;
    if (!AuthGate.instance.isSignedIn) {
      _live = const [];
    } else {
      try {
        final events = await EventService.getLiveNow(limit: 5);
        _live = [
          for (final e in events)
            _LiveHost(
              username: e.hostUsername,
              title: e.title,
              location: NileRoutes.eventOrWatch(
                isLive: true,
                eventId: e.id,
                liveKitEventId: e.liveKitEventId,
              ),
            ),
        ];
      } catch (_) {
        // Offline, or signed out mid-flight. Keep the last known list rather
        // than blinking the menu bar empty on one failed poll.
        return;
      }
    }
    await _setIcon(live: _live.isNotEmpty);
    await _rebuildMenu();
  }

  /// Guarded because setting the icon is a base64 round trip through the
  /// channel, and nothing changes 90 seconds out of 90.
  static Future<void> _setIcon({required bool live}) async {
    if (_showingLive == live) return;
    _showingLive = live;
    await trayManager.setIcon(live ? _liveIcon : _idleIcon, isTemplate: !live);
  }

  static Future<void> _rebuildMenu() async {
    final signedIn = AuthGate.instance.isSignedIn;
    await trayManager.setContextMenu(
      Menu(
        items: [
          if (signedIn) ...[
            MenuItem(
              label: _live.isEmpty ? 'Nothing live right now' : 'Live now',
              disabled: true,
            ),
            for (final host in _live)
              MenuItem(
                label: '${host.username} — ${host.title}',
                toolTip: host.title,
                onClick: (_) => _open(host.location),
              ),
            MenuItem.separator(),
          ],
          MenuItem(label: 'Open Nile', onClick: (_) => MacHost.showWindow()),
          MenuItem(label: 'Quit Nile', onClick: (_) => MacHost.quit()),
        ],
      ),
    );
  }

  static void _open(String location) {
    MacHost.showWindow();
    // `go`, not `push`: picking a show from the menu bar is an external entry
    // point like a notification tap, and should land on a clean stack rather
    // than piling a second viewer — and a second LiveKit connection — on top of
    // whatever was already open.
    nileRouter.go(location);
  }
}

/// Clicking the icon itself opens the menu on macOS, so the only listener that
/// has to exist is the one tray_manager requires to dispatch `onClick`.
class _MacTrayListener with TrayListener {
  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();
}

class _LiveHost {
  const _LiveHost({
    required this.username,
    required this.title,
    required this.location,
  });

  final String username;
  final String title;
  final String location;
}
