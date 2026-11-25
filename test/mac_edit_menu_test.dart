// The Mac Edit menu. Its items declare the real key equivalents (⌘C and
// friends), which means AppKit claims those keystrokes before the Flutter view
// ever sees them — so if `nileInvokeTextIntent` does not actually perform the
// action, the menu does not duplicate copy and paste, it *replaces* them with
// nothing. That is what these tests guard.
//
// The menu bar itself is not pumped: PlatformMenuBar only builds a real menu on
// macOS and its items are not widgets, so what is worth testing is the
// dispatch the items call.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/widgets/nile_menu_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Stands in for the system pasteboard.
  String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return <String, Object?>{'text': clipboard};
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// A focused field holding [text], with [selection] applied.
  Future<TextEditingController> field(
    WidgetTester tester, {
    required String text,
    TextSelection? selection,
  }) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(controller: controller, focusNode: focus),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    if (selection != null) {
      controller.selection = selection;
      await tester.pump();
    }
    return controller;
  }

  testWidgets('Copy puts the selection on the clipboard', (tester) async {
    await field(
      tester,
      text: 'go live tonight',
      selection: const TextSelection(baseOffset: 3, extentOffset: 7),
    );

    nileInvokeTextIntent(CopySelectionTextIntent.copy);
    await tester.pumpAndSettle();

    expect(clipboard, 'live');
  });

  testWidgets('Cut removes the selection and keeps it', (tester) async {
    final controller = await field(
      tester,
      text: 'go live tonight',
      selection: const TextSelection(baseOffset: 0, extentOffset: 3),
    );

    nileInvokeTextIntent(
      const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
    );
    await tester.pumpAndSettle();

    expect(clipboard, 'go ');
    expect(controller.text, 'live tonight');
  });

  testWidgets('Paste inserts at the caret', (tester) async {
    clipboard = 'tonight';
    final controller = await field(
      tester,
      text: 'go live ',
      selection: const TextSelection.collapsed(offset: 8),
    );

    nileInvokeTextIntent(const PasteTextIntent(SelectionChangedCause.keyboard));
    await tester.pumpAndSettle();

    expect(controller.text, 'go live tonight');
  });

  testWidgets('Select All covers the whole field', (tester) async {
    final controller = await field(
      tester,
      text: 'go live tonight',
      selection: const TextSelection.collapsed(offset: 0),
    );

    nileInvokeTextIntent(
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pumpAndSettle();

    expect(controller.selection.start, 0);
    expect(controller.selection.end, 'go live tonight'.length);
  });

  // ⌘C with focus on a button is a real thing to press. AppKit has already
  // eaten the keystroke by then, so this path has to end quietly rather than
  // throw into a menu selection.
  testWidgets('an intent nothing can honour is a no-op', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextButton(onPressed: () {}, child: const Text('Go Live')),
        ),
      ),
    );
    await tester.tap(find.byType(TextButton));
    await tester.pump();

    nileInvokeTextIntent(CopySelectionTextIntent.copy);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(clipboard, isNull);
  });
}
