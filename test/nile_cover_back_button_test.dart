// The whole contract of NileCoverBackButton: it hides itself when there is
// nothing to pop, so Profile can be a root tab and a pushed route at once
// without threading a flag through its 14 call sites. If this regresses, the
// button either vanishes from other people's profiles or appears on your own.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/widgets/nile_cover_action.dart';

void main() {
  testWidgets('hidden when the route cannot pop', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NileCoverBackButton())),
    );

    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('shown on a pushed route, and pops it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const Scaffold(body: NileCoverBackButton()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
  });
}
