// iPad runs the app edge to edge: the status bar sits over the top 24 pt and
// the home indicator over the bottom 20 pt. macOS reports zero for both, so a
// layout can look perfect on the Mac and still put its controls under the
// iPad's clock. These pin the Studio's controls inside the safe area.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/widgets/nile_studio.dart';

const _insets = EdgeInsets.only(top: 24, bottom: 20);

void main() {
  testWidgets('the Studio keeps clear of the iPad status bar and home bar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1366, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: _insets),
          child: child!,
        ),
        home: Scaffold(
          body: NileStudio(
            sources: const [
              NileStudioSource(identity: 'cam', label: 'Your camera'),
            ],
            selectedIdentity: 'cam',
            onSelectSource: (_) {},
            selfIdentity: null,
            stats: const NileStudioStats(isLive: false),
            leading: const SizedBox(key: Key('back'), width: 40, height: 40),
            controls: const SizedBox(key: Key('controls'), height: 40),
            showChatColumn: true,
            chat: const SizedBox(key: Key('chat')),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(const Key('back'))).dy, greaterThan(24));
    expect(
      tester.getBottomLeft(find.byKey(const Key('controls'))).dy,
      lessThanOrEqualTo(1024 - 20),
    );
    expect(
      tester.getBottomLeft(find.byKey(const Key('chat'))).dy,
      lessThanOrEqualTo(1024 - 20),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
