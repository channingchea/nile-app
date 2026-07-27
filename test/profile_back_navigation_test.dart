// Profile is the one screen that is BOTH a root tab and a pushed route, so its
// back button has to appear in one case and not the other. These pump the real
// ProfileScreen (its skeleton branch — no network resolves in a test) to cover
// the wiring end to end; nile_cover_back_button_test.dart covers the widget's
// own contract in isolation.
//
// Supabase is initialized because ProfileScreen reads the current user id, and
// shared_preferences is stubbed because its platform plugin is absent in the
// test VM. Same setup as widget_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nile_app/screens/profile_screen.dart';
import 'package:nile_app/theme.dart';

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
    await tester.pumpWidget(
      MaterialApp(
        theme: nileTheme(Brightness.dark),
        home: const ProfileScreen(userId: 'abc'),
      ),
    );

    expect(find.byTooltip('Back'), findsNothing);
  });

  testWidgets('back button when Profile is pushed', (tester) async {
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
}
