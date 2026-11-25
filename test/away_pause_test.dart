import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/away_pause.dart';

/// docs/plans/cost-controls-and-60-payout.md, phase 4.
void main() {
  test('only a hidden or backgrounded app is away', () {
    expect(isAwayState(AppLifecycleState.paused), isTrue);
    expect(isAwayState(AppLifecycleState.hidden), isTrue);
    // Clicking another Mac window, or a phone's control centre.
    expect(isAwayState(AppLifecycleState.inactive), isFalse);
    expect(isAwayState(AppLifecycleState.resumed), isFalse);
  });

  testWidgets('away and back each fire once per trip', (tester) async {
    final log = <String>[];
    final watcher = AwayWatcher(
      onAway: () => log.add('away'),
      onBack: () => log.add('back'),
    );
    void go(AppLifecycleState s) =>
        tester.binding.handleAppLifecycleStateChanged(s);

    // A phone leaving the app and returning.
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      go(s);
    }
    expect(log, ['away']);
    expect(watcher.away, isTrue);
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      go(s);
    }
    expect(log, ['away', 'back']);

    // A Mac: another window clicked (nothing), minimised (away), shown again
    // without focus (back).
    go(AppLifecycleState.inactive);
    expect(log, ['away', 'back']);
    go(AppLifecycleState.hidden);
    go(AppLifecycleState.inactive);
    expect(log, ['away', 'back', 'away', 'back']);

    watcher.dispose();
    go(AppLifecycleState.hidden);
    expect(log.length, 4);
    go(AppLifecycleState.resumed);
  });
}
