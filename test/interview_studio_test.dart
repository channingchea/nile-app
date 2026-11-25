// Interview mode, host Studio (docs/plans/studio-modes.md, phase 4): the
// invite sheet, host notes, the chat Questions filter and the interview
// layout templates.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/chat_service.dart';
import 'package:nile_app/services/interview.dart';
import 'package:nile_app/services/layout_templates.dart';
import 'package:nile_app/services/profile_service.dart' show UserProfile;
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/services/studio_layouts.dart';
import 'package:nile_app/widgets/host_notes_panel.dart';
import 'package:nile_app/widgets/interview_invite_sheet.dart';
import 'package:nile_app/widgets/nile_studio.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

UserProfile _user(String id, String username) => UserProfile(
  id: id,
  username: username,
  displayName: username.toUpperCase(),
  followerCount: 0,
  followingCount: 0,
  createdAt: DateTime(2026),
);

InterviewGuest _guest(String userId, GuestStatus status, {String? title}) =>
    InterviewGuest(
      id: 'row-$userId',
      userId: userId,
      username: userId,
      status: status,
      title: title,
    );

LiveGraphic _build(StudioGraphic g, int? _) => LiveGraphic(
  id: g.id,
  kind: g.kind,
  title: g.payload['title'] as String?,
  corner: g.payload['corner'] as String?,
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('invite sheet', () {
    late List<({String eventId, String userId, String? title})> invites;
    late List<bool> links;
    late ValueNotifier<List<InterviewGuest>> guests;

    Widget sheet() => _wrap(
      InterviewInviteSheet(
        eventId: 'slug-1',
        guests: guests,
        hostId: 'host',
        search: (q) async => [
          _user('host', 'me'),
          _user('u1', 'ada'),
          _user('u2', 'grace'),
        ],
        invite: ({required eventId, required userId, title}) async =>
            invites.add((eventId: eventId, userId: userId, title: title)),
        link: ({required eventId, rotate = false}) async {
          links.add(rotate);
          return rotate ? 'NEW' : 'OLD';
        },
      ),
    );

    setUp(() {
      invites = [];
      links = [];
      guests = ValueNotifier([_guest('u2', GuestStatus.greenRoom)]);
    });

    testWidgets('searches, leaves out the host, invites with a title', (
      t,
    ) async {
      await t.pumpWidget(sheet());
      await t.enterText(find.byType(TextField).first, 'a');
      await t.pump(InterviewInviteSheet.debounce);
      await t.pump();

      expect(find.text('@me'), findsNothing);
      expect(find.text('@ada'), findsOneWidget);
      // Already on the list: no button.
      final grace = find.byKey(const ValueKey('result-u2'));
      expect(
        find.descendant(of: grace, matching: find.text('Invited')),
        findsOneWidget,
      );

      await t.enterText(find.byType(TextField).at(1), 'Author');
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('result-u1')),
          matching: find.text('Invite'),
        ),
      );
      await t.pump();
      expect(invites, [(eventId: 'slug-1', userId: 'u1', title: 'Author')]);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('result-u1')),
          matching: find.text('Invited'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('lists guests with their status, live', (t) async {
      await t.pumpWidget(sheet());
      expect(find.text('In green room'), findsOneWidget);
      guests.value = [
        _guest('u2', GuestStatus.onStage, title: 'Chef'),
        _guest('u3', GuestStatus.invited),
      ];
      await t.pump();
      expect(find.text('On stage'), findsOneWidget);
      expect(find.text('Chef'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('guest-u3')),
          matching: find.text('Invited'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('share link: get, then rotate after a confirm', (t) async {
      t.view.physicalSize = const Size(1200, 2000);
      addTearDown(t.view.reset);
      await t.pumpWidget(sheet());
      await t.tap(find.text('Get link'));
      await t.pumpAndSettle();
      expect(links, [false]);
      expect(find.textContaining('/g/OLD'), findsOneWidget);

      await t.tap(find.text('New link'));
      await t.pumpAndSettle();
      expect(find.text('Make a new link?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(links, [false]);

      await t.tap(find.text('New link'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'New link').last);
      await t.pumpAndSettle();
      expect(links, [false, true]);
      expect(find.textContaining('/g/NEW'), findsOneWidget);
    });
  });

  group('host notes', () {
    testWidgets('loads, saves after a pause and on close', (t) async {
      final saves = <String>[];
      Widget panel() => _wrap(
        SizedBox(
          width: 280,
          height: 400,
          child: HostNotesPanel(
            eventPk: 'pk',
            load: (_) async => 'Ask about the tour',
            save: (_, body) async => saves.add(body),
          ),
        ),
      );
      await t.pumpWidget(panel());
      await t.pump();
      expect(find.text('Only you can see these.'), findsOneWidget);
      expect(find.text('Ask about the tour'), findsOneWidget);

      await t.enterText(find.byType(TextField), 'One');
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(find.byType(TextField), 'One two');
      await t.pump(const Duration(milliseconds: 400));
      expect(saves, isEmpty);
      await t.pump(HostNotesPanel.debounce);
      expect(saves, ['One two']);

      await t.enterText(find.byType(TextField), 'One two three');
      await t.pumpWidget(_wrap(const SizedBox()));
      expect(saves, ['One two', 'One two three']);
    });

    testWidgets('never saves before the notes load', (t) async {
      final saves = <String>[];
      await t.pumpWidget(
        _wrap(
          SizedBox(
            width: 280,
            height: 400,
            child: HostNotesPanel(
              eventPk: 'pk',
              load: (_) =>
                  Future.delayed(const Duration(seconds: 5), () => 'saved'),
              save: (_, body) async => saves.add(body),
            ),
          ),
        ),
      );
      await t.pumpWidget(_wrap(const SizedBox()));
      await t.pump(const Duration(seconds: 6));
      expect(saves, isEmpty);
    });
  });

  testWidgets('Questions filter shows only lines with a question mark', (
    t,
  ) async {
    ChatMessage m(String text) => ChatMessage(
      senderId: 'v-$text',
      username: 'viewer',
      content: text,
      sentAt: DateTime(2026),
    );
    await t.pumpWidget(
      _wrap(
        SizedBox(
          width: NileStudio.chatColumnWidth,
          child: NileStudioChat(
            messages: [m('Great show'), m('Where was this filmed?')],
            hiddenSenders: const {},
            blockedSenders: const {},
            selfId: null,
            onHide: (_) {},
            onShowAll: () {},
            onBlock: (_) {},
            onReport: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Great show'), findsOneWidget);
    await t.tap(find.text('Questions'));
    await t.pump();
    expect(find.textContaining('Great show'), findsNothing);
    expect(find.textContaining('Where was this filmed?'), findsOneWidget);
  });

  group('interview templates', () {
    test('four, each with a stage arrangement', () {
      final ts = interviewTemplates();
      expect(
        [for (final t in ts) t.id],
        [
          'interview_host_only',
          'interview_one_guest',
          'interview_panel',
          'interview_spotlight',
        ],
      );
      expect(
        [for (final t in ts) t.build((k) => k, 1).stage],
        [
          StageLayout.solo,
          StageLayout.side,
          StageLayout.grid,
          StageLayout.spotlight,
        ],
      );
      // Multicam's own list is untouched.
      expect(layoutTemplates().length, 4);
    });

    for (final cameras in [1, 3]) {
      test('sized to a $cameras-camera show and resolve cleanly', () {
        final positions = [for (var i = 1; i <= cameras; i++) 's$i'];
        for (final t in interviewTemplates(logoPath: 'u/logo.png')) {
          final lib = {
            for (final g in t.graphics)
              'lib-${g.id}': StudioGraphic(
                id: 'lib-${g.id}',
                kind: g.kind,
                name: g.name,
                payload: g.payload,
              ),
          };
          for (final g in t.graphics) {
            expect(StudioGraphic.validate(g.kind, g.payload), isNull);
          }
          final layout = t.build((k) => 'lib-$k', cameras);
          expect(layout.error, isNull, reason: t.id);
          expect(layout.cameras.length, cameras);
          // Survives a save: the stage is in the payload.
          expect(
            StudioLayout.fromPayload(layout.payload, id: 'x', name: 'n').stage,
            layout.stage,
          );
          final r = resolveLayout(
            layout,
            positions: positions,
            graphicsLibrary: lib,
            elementsLibrary: const {},
            build: _build,
          );
          expect(r.missing, isEmpty, reason: t.id);
          expect(r.covered, positions);
          // Every graphic lands on All cameras, which is what the stage shows.
          for (final g in r.graphics.all) {
            expect(g.except, isEmpty);
          }
          expect(r.graphics.bySlot, isEmpty);
        }
      });
    }

    test('host only carries the host lower third; logo only with a kit', () {
      final plain = interviewTemplates(hostName: 'Sam');
      expect(plain.first.graphics.single.payload['title'], 'Sam');
      expect(plain.skip(1).every((t) => t.graphics.isEmpty), isTrue);
      final branded = interviewTemplates(logoPath: 'u/logo.png');
      expect(
        branded.every((t) => t.graphics.any((g) => g.id == 'logo')),
        isTrue,
      );
    });
  });
}
