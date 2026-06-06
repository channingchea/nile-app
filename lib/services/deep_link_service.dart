import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../screens/event_detail_screen.dart';
import '../screens/post_detail_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/viewer_screen.dart';
import 'event_service.dart';
import 'post_service.dart';
import 'profile_service.dart';
import 'share_urls.dart';

/// Handles inbound deep links and routes them via the app's navigator key.
///
/// Two link shapes resolve to the same destinations:
///   • Universal Links / App Links (real https, work whether or not the app is
///     installed): `https://<shareDomain>/e/<id>`, `/p/<id>`, `/u/<username>`.
///   • Legacy custom scheme (only fires when the app is installed):
///     `nile://event/<id>`, `nile://post/<id>`.
class DeepLinkService {
  static final _appLinks = AppLinks();
  static GlobalKey<NavigatorState>? _navKey;
  static StreamSubscription<Uri>? _sub;

  /// Call once after the navigator is mounted. Handles the cold-start link
  /// (app opened by a link) and subscribes to links while running.
  static Future<void> init(GlobalKey<NavigatorState> navKey) async {
    _navKey = navKey;
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
    final nav = _navKey?.currentState;
    if (nav == null) return;

    switch (parsed.kind) {
      case 'post':
        final post = await PostService.fetchById(parsed.value);
        if (post == null) return;
        nav.push(MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)));
      case 'event':
        final event = await EventService.fetchById(parsed.value);
        if (event == null) return;
        nav.push(MaterialPageRoute(
          builder: (_) => event.isLive
              ? ViewerScreen(initialEventId: event.liveKitEventId)
              : EventDetailScreen(event: event),
        ));
      case 'profile':
        final userId = await ProfileService.idForUsername(parsed.value);
        if (userId == null) return;
        nav.push(MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)));
    }
  }
}
