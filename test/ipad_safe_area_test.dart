// iPad runs the app edge to edge: the status bar sits over the top of the
// window and (on Face ID iPads) the home indicator over the bottom. macOS
// reports zero for both, so a layout can look perfect on the Mac and still put
// its controls under the iPad's clock. These pump the desktop shell and the
// Studio at every current iPad screen, in both orientations, with that iPad's
// real insets, and check nothing overflows and nothing sits under the bars.
//
// Supabase is initialized with throwaway credentials and shared_preferences is
// stubbed, same as desktop_shell_test.dart — the rails fire service calls on
// mount and need a client to fail against.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nile_app/screens/studio_preview_screen.dart';
import 'package:nile_app/services/studio_mode.dart';
import 'package:nile_app/theme.dart';
import 'package:nile_app/widgets/nile_app_shell.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:nile_app/widgets/nile_studio_mode_switch.dart';
import 'package:nile_app/widgets/studio_preview_demo.dart';

/// Portrait size in points, status-bar height, home-indicator height.
typedef _IPad = ({String name, Size size, double top, double bottom});

const List<_IPad> _ipads = [
  (
    name: 'iPad mini (6th gen, A17 Pro)',
    size: Size(744, 1133),
    top: 24,
    bottom: 20,
  ),
  (
    name: 'iPad (9th gen, Home button)',
    size: Size(810, 1080),
    top: 20,
    bottom: 0,
  ),
  (
    name: 'iPad (10th gen, A16) / Air 11"',
    size: Size(820, 1180),
    top: 24,
    bottom: 20,
  ),
  (
    name: 'iPad Pro 11" (1st-4th gen)',
    size: Size(834, 1194),
    top: 24,
    bottom: 20,
  ),
  (name: 'iPad Pro 11" (M4/M5)', size: Size(834, 1210), top: 24, bottom: 20),
  (
    name: 'iPad Pro 12.9" / Air 13"',
    size: Size(1024, 1366),
    top: 24,
    bottom: 20,
  ),
  (name: 'iPad Pro 13" (M4/M5)', size: Size(1032, 1376), top: 24, bottom: 20),
];

/// Sizes the test window like the iPad, insets included.
void _becomeIPad(WidgetTester tester, Size size, double top, double bottom) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  final insets = FakeViewPadding(top: top, bottom: bottom);
  tester.view.padding = insets;
  tester.view.viewPadding = insets;
  addTearDown(tester.view.reset);
}

/// The Studio as Studio Preview composes it, with a full chat — the worst case.
Widget _studio(StudioPreviewDemo demo, {required bool chatColumn}) =>
    NileStudio(
      sources: [
        const NileStudioSource(
          identity: 'preview:self',
          label: 'Your camera',
          isLocal: true,
          isMasterAudio: true,
        ),
        ...StudioPreviewDemo.crew,
      ],
      selectedIdentity: null,
      onSelectSource: (_) {},
      selfIdentity: 'preview:self',
      stats: NileStudioStats(
        isLive: demo.isLive,
        elapsed: demo.elapsed,
        remaining: demo.remaining,
        viewerCount: demo.viewerCount,
        readyCount: demo.readyCount,
        crewCount: demo.crewCount,
        audioSourceLabel: 'Your mic',
      ),
      leading: IconButton(
        key: const Key('back'),
        onPressed: () {},
        icon: const Icon(Icons.arrow_back),
      ),
      trailing: IconButton(
        key: const Key('settings'),
        onPressed: () {},
        icon: const Icon(Icons.settings),
      ),
      center: NileStudioModeSwitch(
        value: StudioMode.multicam,
        onChanged: (_) {},
      ),
      banner: StudioPreviewBanner(live: demo.isLive, onChanged: (_) {}),
      controls: NileStudioControlBar(
        isLive: demo.isLive,
        isHost: true,
        isMasterAudio: true,
        videoEnabled: true,
        showChatToggle: !chatColumn,
        showScreenShare: true,
        cameraControl: const NileStudioIconButton(
          onPressed: null,
          tooltip: 'Choose camera',
          icon: Icons.cameraswitch_outlined,
        ),
        onLeave: () {},
        leaveLabel: 'Exit',
        leaveIcon: Icons.close,
      ),
      showChatColumn: chatColumn,
      chat: chatColumn
          ? NileStudioChat(
              key: const Key('chat'),
              messages: demo.messages,
              hiddenSenders: demo.hiddenSenders,
              blockedSenders: const {},
              selfId: null,
              onHide: (m) => demo.hide(m.senderId),
              onShowAll: demo.showAll,
              onBlock: (_) {},
              onReport: (_) {},
            )
          : null,
    );

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

  for (final ipad in _ipads) {
    for (final landscape in [false, true]) {
      final size = landscape ? ipad.size.flipped : ipad.size;
      final label =
          '${ipad.name} ${landscape ? 'landscape' : 'portrait'} '
          '(${size.width.toInt()}×${size.height.toInt()})';
      final bottomLimit = size.height - ipad.bottom;

      testWidgets('$label — Studio fits inside the safe area', (tester) async {
        _becomeIPad(tester, size, ipad.top, ipad.bottom);
        final chatColumn = NileBreakpoints.classify(size).hasContextRail;
        final demo = StudioPreviewDemo();
        for (var i = 0; i < StudioPreviewDemo.maxMessages; i++) {
          demo.addMessage();
        }

        for (final live in [false, true]) {
          demo.isLive = live;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              home: Scaffold(body: _studio(demo, chatColumn: chatColumn)),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');

          for (final key in ['back', 'settings']) {
            expect(
              tester.getTopLeft(find.byKey(Key(key))).dy,
              greaterThanOrEqualTo(ipad.top),
              reason: '$key under the status bar',
            );
          }
          expect(
            tester.getTopLeft(find.byType(NileStudioModeSwitch)).dy,
            greaterThanOrEqualTo(ipad.top),
          );
          expect(
            tester.getBottomLeft(find.byType(NileStudioControlBar)).dy,
            lessThanOrEqualTo(bottomLimit),
            reason: 'controls under the home indicator',
          );
          expect(
            tester
                .getBottomRight(find.text(live ? 'End Stream' : 'Start Show'))
                .dy,
            lessThanOrEqualTo(bottomLimit),
          );
          if (chatColumn) {
            expect(
              tester.getBottomLeft(find.byKey(const Key('chat'))).dy,
              lessThanOrEqualTo(bottomLimit),
            );
          }
        }

        await tester.pumpWidget(const SizedBox());
        demo.dispose();
      });

      testWidgets('$label — top bar clears the status bar', (tester) async {
        _becomeIPad(tester, size, ipad.top, ipad.bottom);
        late EdgeInsets screenPadding;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: nileTheme(Brightness.dark),
            home: NileAppShell(
              location: '/',
              child: Builder(
                builder: (context) {
                  screenPadding = MediaQuery.paddingOf(context);
                  return const SizedBox.expand(key: Key('screen'));
                },
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'overflow');

        // Every iPad gets the desktop chrome, so the search pill is there.
        final search = find.text('Search events, people, topics');
        expect(search, findsOneWidget);
        expect(tester.getTopLeft(search).dy, greaterThanOrEqualTo(ipad.top));

        // The screen starts below the top bar and isn't told to pad for the
        // status bar a second time; the home-indicator inset still reaches it.
        expect(
          tester.getTopLeft(find.byKey(const Key('screen'))).dy,
          greaterThan(ipad.top),
        );
        expect(screenPadding.top, 0);
        expect(screenPadding.bottom, ipad.bottom);

        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
