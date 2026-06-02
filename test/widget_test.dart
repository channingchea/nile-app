// Smoke test: the app builds and renders its first frame without throwing.
//
// NileApp reads Supabase.instance during build, so the test initializes
// Supabase with throwaway credentials first. Supabase persists its session via
// shared_preferences, whose platform plugin isn't available in the test VM, so
// we stub that method channel to return empty. We pump a single frame (not
// pumpAndSettle) so the _AuthGate loading state renders without a live session.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nile_app/main.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Stub shared_preferences so Supabase's local storage init succeeds.
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

  testWidgets('NileApp builds its first frame', (tester) async {
    await tester.pumpWidget(const NileApp());

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
