// Phase 5b — the desktop shell. Covers the two things most likely to break
// silently: the breakpoint boundaries themselves (off-by-one here changes which
// layout every screen gets) and whether the rails actually fit at the width
// they claim to need.
//
// Each pumped test ends by pumping an empty tree, because both rails start a
// periodic refresh timer and flutter_test fails a test that leaves one pending.
//
// Supabase is initialized with throwaway credentials and shared_preferences is
// stubbed, same as widget_test.dart — the rails fire service calls on mount and
// need a client to fail against rather than a null one to crash on.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nile_app/theme.dart';
import 'package:nile_app/widgets/nile_context_rail.dart';
import 'package:nile_app/widgets/nile_destinations.dart';
import 'package:nile_app/widgets/nile_glass_nav_bar.dart';
import 'package:nile_app/widgets/nile_keyboard_list.dart';
import 'package:nile_app/widgets/nile_nav_rail.dart';

/// The rail takes entries, not bare destinations, since three of its real rows
/// are routes rather than branches. These fixtures stay branch-only: what the
/// widget tests below measure is width and labelling, which is the same either
/// way, and the real composition is asserted in desktop_layouts_test.dart.
List<NileRailEntry> get _entries =>
    [for (final (i, d) in _destinations.indexed) NileRailEntry.branch(d, i)];

const _destinations = [
  NileGlassDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  NileGlassDestination(
    icon: Icons.search_outlined,
    selectedIcon: Icons.search,
    label: 'Discover',
  ),
  NileGlassDestination(
    icon: Icons.send_outlined,
    selectedIcon: Icons.send,
    label: 'Messages',
  ),
  NileGlassDestination(
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    label: 'Profile',
  ),
];

Future<void> _pumpAt(
  WidgetTester tester,
  Size size,
  Widget child,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: nileTheme(Brightness.dark), home: child),
  );
  await tester.pump();
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

  group('breakpoints', () {
    NileWindowClass at(double w, [double h = 1000]) =>
        NileBreakpoints.classify(Size(w, h));

    test('classify is inclusive at each lower bound', () {
      expect(at(739), NileWindowClass.compact);
      expect(at(740), NileWindowClass.medium);
      expect(at(1023), NileWindowClass.medium);
      expect(at(1024), NileWindowClass.expanded);
      expect(at(1179), NileWindowClass.expanded);
      expect(at(1180), NileWindowClass.wide);
    });

    // The whole point of dropping the threshold to 740: every iPad, in every
    // orientation, is a desktop-layout device.
    test('every iPad gets the desktop layout in both orientations', () {
      const ipads = <String, Size>{
        'mini portrait': Size(744, 1133),
        'mini landscape': Size(1133, 744),
        '11" portrait': Size(820, 1180),
        '11" landscape': Size(1180, 820),
        '13" portrait': Size(1024, 1366),
        '13" landscape': Size(1366, 1024),
      };
      ipads.forEach((name, size) {
        expect(
          NileBreakpoints.classify(size).hasNavRail,
          isTrue,
          reason: name,
        );
      });
    });

    // Wider than an iPad is tall, but only ~430 pt high — a rail would eat most
    // of the vertical room. Height is what tells the two apart.
    test('a phone in landscape stays on the phone layout', () {
      expect(at(956, 440), NileWindowClass.compact);
      expect(at(874, 402), NileWindowClass.compact);
    });

    test('an iPad Split View pane stays on the phone layout', () {
      expect(at(507, 1133), NileWindowClass.compact);
      expect(at(639, 1133), NileWindowClass.compact);
    });

    test('the phone keeps the bottom nav and gets no rails', () {
      const compact = NileWindowClass.compact;
      expect(compact.hasNavRail, isFalse);
      expect(compact.hasContextRail, isFalse);
    });

    test('the icon rail arrives before labels and the context rail', () {
      const medium = NileWindowClass.medium;
      expect(medium.hasNavRail, isTrue);
      expect(medium.navRailLabelled, isFalse);
      expect(medium.hasContextRail, isFalse);
    });

    test('an iPad in portrait gets a labelled rail but no context rail', () {
      const expanded = NileWindowClass.expanded;
      expect(expanded.navRailLabelled, isTrue);
      expect(expanded.hasContextRail, isFalse);
    });

    test('all three zones only at wide', () {
      const wide = NileWindowClass.wide;
      expect(wide.hasNavRail, isTrue);
      expect(wide.navRailLabelled, isTrue);
      expect(wide.hasContextRail, isTrue);
    });

    test('the content column is still readable at the narrowest wide window',
        () {
      const zones = NileNavRail.expandedWidth + NileContextRail.minWidth;
      // What's left for the content column at 1180 — wider than the 600 pt
      // phone column, which is the bar the context rail has to clear to earn
      // its place.
      expect(NileBreakpoints.wide - zones, greaterThan(NileMaxWidth.compact));
    });

    // The zone arithmetic the desktop shell runs, kept here so a change to any
    // one constant has to face the widths it produces on real windows.
    ({double content, double context}) zones(double windowWidth) {
      final available = windowWidth - NileNavRail.expandedWidth;
      final content = math.min(
        available - NileContextRail.minWidth,
        NileMaxWidth.desktop,
      );
      return (content: content, context: available - content);
    }

    test('both rails stay pinned: the zones always fill the window exactly', () {
      for (final width in [1180.0, 1280.0, 1366.0, 1512.0, 1682.0, 1728.0]) {
        final z = zones(width);
        expect(
          NileNavRail.expandedWidth + z.content + z.context,
          width,
          reason: '$width',
        );
        expect(z.context, greaterThanOrEqualTo(NileContextRail.minWidth),
            reason: '$width');
        expect(z.content, lessThanOrEqualTo(NileMaxWidth.desktop),
            reason: '$width');
      }
    });

    test('the context rail only grows once the column hits its ceiling', () {
      // 1366 (13" iPad landscape): column still under the ceiling, rail at its
      // design width.
      expect(zones(1366).context, NileContextRail.minWidth);
      // 1682 (a maximised 16" MacBook): column capped, rail absorbs the rest.
      expect(zones(1682).content, NileMaxWidth.desktop);
      expect(zones(1682).context, greaterThan(NileContextRail.minWidth));
    });
  });

  group('NileMaxWidth', () {
    testWidgets('is the 600 phone column below the iPad threshold',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(700, 1000),
        const Align(
          alignment: Alignment.topCenter,
          child: NileMaxWidth(child: SizedBox(height: 10, width: 2000)),
        ),
      );
      expect(NileMaxWidth.compact, 600);
      expect(tester.getSize(find.byType(SizedBox).last).width, 600);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('widens to the desktop column from iPad up', (tester) async {
      await _pumpAt(
        tester,
        const Size(1400, 1000),
        const Align(
          alignment: Alignment.topCenter,
          child: NileMaxWidth(child: SizedBox(height: 10, width: 2000)),
        ),
      );
      final size = tester.getSize(find.byType(SizedBox).last);
      expect(size.width, NileMaxWidth.desktop);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('NileNavRail', () {
    Widget rail({required bool labelled}) => Scaffold(
      body: Row(
        children: [
          NileNavRail(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            entries: _entries,
            labelled: labelled,
            onCreate: () {},
            onSettings: () {},
          ),
          const Expanded(child: SizedBox()),
        ],
      ),
    );

    testWidgets('icon-only rail is 72 wide and hides labels', (tester) async {
      await _pumpAt(tester, const Size(1000, 800), rail(labelled: false));
      expect(
        tester.getSize(find.byType(NileNavRail)).width,
        NileNavRail.collapsedWidth,
      );
      expect(find.text('Discover'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('labelled rail is 214 wide and names every destination',
        (tester) async {
      await _pumpAt(tester, const Size(1400, 800), rail(labelled: true));
      expect(
        tester.getSize(find.byType(NileNavRail)).width,
        NileNavRail.expandedWidth,
      );
      for (final d in _destinations) {
        expect(find.text(d.label), findsOneWidget, reason: d.label);
      }
      expect(find.text('Create'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    // 800 px is short enough that a rail laying itself out naively overflows.
    testWidgets('survives a short window', (tester) async {
      await _pumpAt(tester, const Size(1400, 620), rail(labelled: true));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('NileContextRail', () {
    testWidgets('defaults to its design width and takes a slot override',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(1400, 800),
        const Scaffold(
          body: Row(
            children: [
              Expanded(child: SizedBox()),
              NileContextRail(child: Text('chat goes here')),
            ],
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(NileContextRail)).width,
        NileContextRail.minWidth,
      );
      // Phase 7 swaps chat in through this slot rather than forking the widget.
      expect(find.text('chat goes here'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('keyboard list', () {
    late List<String> fired;

    Widget list() => Scaffold(
      body: NileKeyboardList(
        child: ListView(
          children: [
            for (var i = 0; i < 3; i++)
              NileKeyboardItem(
                index: i,
                onOpen: () => fired.add('open$i'),
                onLike: i == 2 ? null : () => fired.add('like$i'),
                child: SizedBox(height: 120, child: Text('card $i')),
              ),
          ],
        ),
      ),
    );

    setUp(() => fired = []);

    testWidgets('J/K walk the list and L acts on the selection',
        (tester) async {
      await _pumpAt(tester, const Size(1400, 900), list());
      final state = tester.state<NileKeyboardListState>(
        find.byType(NileKeyboardList),
      );

      // Nothing is selected until the first keystroke, so a bare Enter keeps
      // whatever meaning the focused widget already gave it.
      expect(state.selection.value, -1);
      expect(state.trigger(NileListAction.open), isFalse);

      state.move(1);
      expect(state.selection.value, 0);
      state.move(1);
      expect(state.selection.value, 1);
      state.move(-1);
      expect(state.selection.value, 0);
      // Clamped at the ends rather than wrapping — a feed has no bottom.
      state.move(-1);
      expect(state.selection.value, 0);

      expect(state.trigger(NileListAction.like), isTrue);
      expect(fired, ['like0']);

      expect(state.trigger(NileListAction.open), isTrue);
      expect(fired, ['like0', 'open0']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an item with no like path lets the keystroke fall through',
        (tester) async {
      await _pumpAt(tester, const Size(1400, 900), list());
      final state = tester.state<NileKeyboardListState>(
        find.byType(NileKeyboardList),
      );
      state.move(1);
      state.move(1);
      state.move(1);
      expect(state.selection.value, 2);
      // Card 2 stands in for an advertiser creative: no like, so L is not
      // swallowed.
      expect(state.trigger(NileListAction.like), isFalse);
      expect(state.trigger(NileListAction.open), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('items do not register on a phone-width window',
        (tester) async {
      await _pumpAt(tester, const Size(600, 900), list());
      final state = tester.state<NileKeyboardListState>(
        find.byType(NileKeyboardList),
      );
      state.move(1);
      expect(state.selection.value, -1);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
