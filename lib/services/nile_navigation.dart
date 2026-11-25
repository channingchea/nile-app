import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The app's router: a [GoRouter] whose [push] never stacks a second copy of
/// the screen already on top (pressing Settings again while Settings is open
/// does nothing), and ignores the same push repeated within [repeatWindow]
/// (a double-tap, before the first push has landed). Every `context.push` and
/// `nileRouter.push` in the app goes through here.
class NileGoRouter extends GoRouter {
  NileGoRouter({
    required List<RouteBase> routes,
    GoRouterRedirect? redirect,
    super.refreshListenable,
    super.initialLocation,
    super.navigatorKey,
  }) : super.routingConfig(
         routingConfig: ValueNotifier(
           redirect == null
               ? RoutingConfig(routes: routes)
               : RoutingConfig(routes: routes, redirect: redirect),
         ),
       );

  static const repeatWindow = Duration(milliseconds: 700);

  String? _lastPush;
  DateTime _lastPushAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<T?> push<T extends Object?>(String location, {Object? extra}) async {
    final now = DateTime.now();
    if (isDuplicatePush(
      location: location,
      showing: _showing,
      lastPush: _lastPush,
      sinceLastPush: now.difference(_lastPushAt),
    )) {
      return null;
    }
    _lastPush = location;
    _lastPushAt = now;
    return super.push<T>(location, extra: extra);
  }

  /// The location on top right now, or null before the first route resolves.
  String? get _showing {
    try {
      return state.uri.toString();
    } catch (_) {
      return null;
    }
  }
}

/// Whether pushing [location] would only stack a duplicate: it is already on
/// top, or the very same push happened a moment ago.
@visibleForTesting
bool isDuplicatePush({
  required String location,
  required String? showing,
  required String? lastPush,
  required Duration sinceLastPush,
}) {
  String norm(String l) {
    final u = Uri.parse(l);
    final path = u.path.length > 1 && u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.hasQuery ? '$path?${u.query}' : path;
  }

  final target = norm(location);
  if (showing != null && norm(showing) == target) return true;
  return lastPush != null &&
      norm(lastPush) == target &&
      sinceLastPush < NileGoRouter.repeatWindow;
}

/// Plain [Navigator] pushes (photo viewer, crop, menus) with the same double-
/// tap guard: a second push within [NileGoRouter.repeatWindow] of the last one
/// is ignored, so a quick double tap never opens two copies.
abstract final class NileNav {
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<T?> push<T extends Object?>(
    BuildContext context,
    Route<T> route, {
    bool rootNavigator = false,
  }) async {
    final now = DateTime.now();
    if (now.difference(_lastAt) < NileGoRouter.repeatWindow) return null;
    _lastAt = now;
    return Navigator.of(context, rootNavigator: rootNavigator).push(route);
  }

  @visibleForTesting
  static void debugReset() => _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
}
