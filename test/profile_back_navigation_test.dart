// Profile is the one screen that is BOTH a root tab and a pushed route, so its
// back button has to appear in one case and not the other. These pump the real
// ProfileScreen (its skeleton branch — no network resolves in a test) to cover
// the wiring end to end; nile_cover_back_button_test.dart covers the widget's
// own contract in isolation.
//
// Supabase is initialized because ProfileScreen reads the current user id, and
// shared_preferences is stubbed because its platform plugin is absent in the
// test VM. Same setup as widget_test.dart.
//
// EVERY case here pins the surface to a phone. flutter_test's default is
// 800x600, which since Phase 7 is a *desktop* window class — so without the
// pin these silently started asserting the desktop layout, where back lives in
// the chrome's top bar and the cover button is deliberately absent. The last
// test covers that case on purpose.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nile_app/screens/profile_screen.dart';
import 'package:nile_app/theme.dart';

/// A phone-sized surface. The cover back button is a compact-layout
/// affordance; on a desktop window the chrome's top bar owns back instead.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Wide enough for a nav rail, so the chrome is what carries back.
void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return <String, Object>{};
      return null;
    });

    await Supabase.initialize(
      url: 'https://test.supabase.co',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('no back button when Profile is the root tab', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: nileTheme(Brightness.dark),
        home: const ProfileScreen(userId: 'abc'),
      ),
    );

    expect(find.byTooltip('Back'), findsNothing);
  });

  testWidgets('back button when Profile is pushed', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: nileTheme(Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ProfileScreen(userId: 'abc'),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byTooltip('Back'), findsOneWidget);
  });

  testWidgets('no cover back button on a desktop window — the chrome has it', (
    tester,
  ) async {
    _desktop(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: nileTheme(Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ProfileScreen(userId: 'abc'),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Pushed, but wide: NileAppShell's top bar carries back, so the screen
    // must not draw a second one over its cover photo.
    expect(find.byTooltip('Back'), findsNothing);
  });
}
