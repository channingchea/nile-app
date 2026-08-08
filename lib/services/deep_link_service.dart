import 'dart:async';

import 'package:app_links/app_links.dart';

import '../router.dart';
import 'destinations.dart';
import 'share_urls.dart';

/// Handles inbound deep links and routes them through the app router.
///
/// Two link shapes resolve to the same destinations:
///   • Universal Links / App Links (real https, work whether or not the app is
///     installed): `https://<shareDomain>/e/<id>`, `/p/<id>`, `/u/<username>`.
///   • Legacy custom scheme (only fires when the app is installed):
///     `nile://event/<id>`, `nile://post/<id>`.
class DeepLinkService {
  static final _appLinks = AppLinks();
  static StreamSubscription<Uri>? _sub;

  /// Call once after the router is mounted. Handles the cold-start link
  /// (app opened by a link) and subscribes to links while running.
  static Future<void> init() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _route(initial);
    } catch (_) {}
    _sub ??= _appLinks.uriLinkStream.listen(
      (uri) => _route(uri),
      onError: (_) {},
    );
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  /// Normalizes an inbound URI to `(kind, value)` where kind ∈ {event, post,
  /// profile}, or null if it's not a recognized Nile link.
  static ({String kind, String value})? _parse(Uri uri) {
    // Universal / App Links: https://<shareDomain>/{e|p|u}/<value>
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host == ShareUrls.shareDomain) {
      final segs = uri.pathSegments;
      if (segs.length < 2 || segs[1].isEmpty) return null;
      switch (segs[0]) {
        case 'e':
          return (kind: 'event', value: segs[1]);
        case 'p':
          return (kind: 'post', value: segs[1]);
        case 'u':
          return (kind: 'profile', value: segs[1]);
      }
      return null;
    }
    // Legacy custom scheme: nile://<kind>/<id> (host = kind).
    if (uri.scheme == 'nile') {
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (id.isEmpty) return null;
      if (uri.host == 'event') return (kind: 'event', value: id);
      if (uri.host == 'post') return (kind: 'post', value: id);
    }
    return null;
  }

  static Future<void> _route(Uri uri) async {
    final parsed = _parse(uri);
    if (parsed == null) return;
    final destination = await Destinations.forLink(
      kind: parsed.kind,
      value: parsed.value,
    );
    if (destination == null) return;

    // The user arrived from outside the app, so land them on a fresh stack:
    // `go` replaces what's there, where in-app navigation pushes onto it.
    // Repeated links would otherwise pile duplicate screens on top of whatever
    // was already pushed (worst case: a second live ViewerScreen, i.e. two
    // simultaneous LiveKit connections).
    nileRouter.go(destination.location, extra: destination.extra);
  }
}
