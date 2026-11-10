import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nile_app/screens/studio_preview_screen.dart';
import 'package:nile_app/theme.dart';
import 'package:nile_app/widgets/nile_app_shell.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll') return <String, Object>{};
          return null;
        });
    await Supabase.initialize(url: 'https://test.supabase.co', anonKey: 'k');
  });

  for (final size in const [Size(1440, 900), Size(1100, 800), Size(800, 700)]) {
    testWidgets('navigate to studio preview at $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final errors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.toString().split('\n').take(25).join('\n'));
      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          ShellRoute(
            builder: (_, s, child) => NileAppShell(location: s.uri.path, child: child),
            routes: [
              GoRoute(path: '/a', builder: (_, _) => const Scaffold(body: Text('A'))),
              GoRoute(path: '/studio-preview', builder: (_, _) => const StudioPreviewScreen()),
            ],
          ),
        ],
      );
      await t.pumpWidget(MaterialApp.router(theme: nileTheme(Brightness.dark), routerConfig: router));
      await t.pump();
      router.push('/studio-preview');
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      router.pop();
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      FlutterError.onError = old;
      // ignore: avoid_print
      print('ERRORS at $size: ${errors.length}\n${errors.join('\n-----\n')}');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 6));
    });
  }
}
