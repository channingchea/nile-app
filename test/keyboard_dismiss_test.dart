// Guards the global tap-to-dismiss wired into MaterialApp.builder (main.dart)
// against an onboarding-shaped tree: AppBar + Column + PageView + a scroll view
// holding the field. Taps on any blank area — scroll-view padding, the gap
// under the field, the app bar, the button padding — must drop focus, and real
// controls must still win the gesture arena.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the builder wiring in main.dart.
Widget _app({required Widget body, PreferredSizeWidget? appBar}) => MaterialApp(
  builder: (_, child) => GestureDetector(
    onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
    child: child ?? const SizedBox.shrink(),
  ),
  home: Scaffold(appBar: appBar, body: body),
);

Widget _onboardingShaped(FocusNode node, {VoidCallback? onNext}) => Column(
  children: [
    const SizedBox(height: 12),
    const Text('Tell people about you'),
    Expanded(
      child: PageView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Text('caption'),
                const SizedBox(height: 32),
                TextField(focusNode: node, maxLines: 4),
                // Tall enough to actually scroll — onDrag only fires when the
                // content overflows, which is exactly the keyboard-up case.
                const SizedBox(height: 600),
              ],
            ),
          ),
        ],
      ),
    ),
    Padding(
      padding: const EdgeInsets.all(24),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: onNext ?? () {},
          child: const Text('Next'),
        ),
      ),
    ),
  ],
);

void main() {
  testWidgets('blank areas drop focus', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _app(
        appBar: AppBar(title: const Text('Welcome to Nile')),
        body: _onboardingShaped(node),
      ),
    );

    const spots = {
      'gap under the field': Offset(400, 420),
      'scroll view side padding': Offset(6, 400),
      'app bar': Offset(400, 40),
      'padding around the Next button': Offset(20, 560),
    };

    for (final spot in spots.entries) {
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(node.hasFocus, isTrue);

      await tester.tapAt(spot.value);
      await tester.pump();
      expect(node.hasFocus, isFalse, reason: 'tapping ${spot.key}');
    }
  });

  testWidgets('dragging the step content dismisses too', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(_app(body: _onboardingShaped(node)));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(node.hasFocus, isTrue);

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -80));
    await tester.pump();
    expect(node.hasFocus, isFalse);
  });

  testWidgets('the Next button still receives its tap', (tester) async {
    final node = FocusNode();
    var taps = 0;
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _app(body: _onboardingShaped(node, onNext: () => taps++)),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(taps, 1, reason: 'the root detector must not swallow button taps');
  });
}
