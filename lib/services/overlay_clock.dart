import 'package:flutter/widgets.dart';

import 'server_clock.dart';

/// The moment overlays are drawn at. Live, nothing provides one and overlays
/// use the clock they always have; a replay provides the moment in the
/// recording, so clocks, countdowns and auto-hides read as they did on air
/// (studio live elements, phase 6).
class OverlayClock extends InheritedWidget {
  const OverlayClock({super.key, required this.now, required super.child});

  /// Wall-clock ms (server time) for "now".
  final int Function() now;

  /// The provided moment, or null live.
  static int? maybeNow(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OverlayClock>()?.now();

  /// The provided moment, else the server clock.
  static int nowOf(BuildContext context) =>
      maybeNow(context) ?? ServerClock.now();

  @override
  bool updateShouldNotify(OverlayClock old) => old.now != now;
}
