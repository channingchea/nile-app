// The docked mini player is mounted in MaterialApp.builder — above the router,
// so it inherits no Navigator overlay. Its Tooltips need one, and without it
// Flutter throws "No Overlay widget found" and paints an ErrorWidget over the
// dock. Guards the private Overlay that NileMiniPlayerHost installs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/mini_player.dart';
import 'package:nile_app/widgets/nile_mini_player.dart';
import 'package:video_player/video_player.dart';

void main() {
  testWidgets('docked player renders its tooltips without an ErrorWidget', (
    tester,
  ) async {
    // Never initialised, so no platform channel is touched; the dock falls back
    // to 16/9 and an empty texture, which is all this test needs.
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/replay.m3u8'),
    );
    MiniPlayer.instance.adopt(
      controller,
      eventId: 'evt-1',
      title: 'Sunday Set',
      subtitle: 'Replay',
    );
    // Hands the controller back instead of closing, so nothing tries to dispose
    // an uninitialised platform player after the test.
    addTearDown(() => MiniPlayer.instance.reclaim('evt-1'));

    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            NileMiniPlayerHost(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(),
      ),
    );
    // adopt() notifies after the frame, so the dock appears on the second pump.
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(Tooltip), findsWidgets);
    expect(find.byWidgetPredicate((w) => w is ErrorWidget), findsNothing);
  });
}
