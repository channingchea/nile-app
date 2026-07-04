import 'package:flutter/widgets.dart';

/// App-wide lifecycle signal. A single [WidgetsBindingObserver] registered at
/// the app root pushes state changes here; screens listen instead of each
/// registering their own observer.
///
/// The common use is "refresh on resume": after the OS suspends the app (screen
/// lock, backgrounding, laptop sleep) realtime channels and visible data can go
/// stale, so a screen listens and re-fetches / re-subscribes when the value
/// returns to [AppLifecycleState.resumed].
class AppLifecycle {
  AppLifecycle._();
  static final AppLifecycle instance = AppLifecycle._();

  final ValueNotifier<AppLifecycleState> state =
      ValueNotifier<AppLifecycleState>(AppLifecycleState.resumed);
}
