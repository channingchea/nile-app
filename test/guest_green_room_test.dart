// Interview mode, the guest's side (docs/plans/studio-modes.md, phase 3): the
// /g share link, the guest_invited notification, what a guest subscribes to,
// and the green room's LiveKit-free pieces.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:livekit_client/livekit_client.dart' show ConnectionQuality;
import 'package:nile_app/router.dart';
import 'package:nile_app/screens/guest_green_room_screen.dart';
import 'package:nile_app/services/backstage.dart';
import 'package:nile_app/services/deep_link_service.dart';
import 'package:nile_app/services/destinations.dart';
import 'package:nile_app/services/notification_service.dart';
import 'package:nile_app/widgets/guest_parts.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('guest share link', () {
    test('https://links.joinnile.com/g/<code> parses as a guest link', () {
      expect(
        DeepLinkService.parse(
          Uri.parse('https://links.joinnile.com/g/abcdefgh23'),
        ),
        (kind: 'guest', value: 'abcdefgh23'),
      );
    });

    test('no code, or another host, is not a guest link', () {
      expect(
        DeepLinkService.parse(Uri.parse('https://links.joinnile.com/g/')),
        isNull,
      );
      expect(
        DeepLinkService.parse(Uri.parse('https://example.com/g/abcdefgh23')),
        isNull,
      );
    });

    test('the other link kinds still parse', () {
      expect(
        DeepLinkService.parse(Uri.parse('https://links.joinnile.com/e/1')),
        (kind: 'event', value: '1'),
      );
    });

    test('routes to /g/<code> without a fetch', () async {
      final d = await Destinations.forLink(kind: 'guest', value: 'abcdefgh23');
      expect(d?.location, '/g/abcdefgh23');
      expect(NileRoutes.guestLink('abcdefgh23'), '/g/abcdefgh23');
    });
  });

  group('guest_invited notification', () {
    test('parses from an FCM payload and from a notifications row', () {
      expect(
        Destinations.typeFromPush('guest_invited'),
        NotificationType.guestInvited,
      );
      final n = AppNotification.fromJson({
        'id': 'n1',
        'recipient_id': 'u1',
        'actor_id': 'h1',
        'actor': {'username': 'host'},
        'type': 'guest_invited',
        'entity_id': 'ev1',
        'created_at': '2026-11-01T20:00:00Z',
      });
      expect(n.type, NotificationType.guestInvited);
    });

    test('a tap opens the green room for the event', () async {
      final d = await Destinations.forNotification(
        NotificationType.guestInvited,
        entityId: 'ev1',
      );
      expect(d?.location, '/event/ev1/green-room');
      expect(NileRoutes.eventGreenRoom('ev1'), '/event/ev1/green-room');
      expect(
        await Destinations.forNotification(NotificationType.guestInvited),
        isNull,
      );
    });
  });

  group('what a guest subscribes to', () {
    ({bool audio, bool video}) wants(
      String id, {
      String? role = 'guest',
      Set<String> visible = const {},
      String? master,
      bool showAudio = true,
    }) => guestWants(
      identity: id,
      role: role,
      backstage: 'backstage-show',
      visible: visible,
      master: master,
      showAudio: showAudio,
    );

    test('green-room peers: nothing', () {
      expect(wants('guest-b'), (audio: false, video: false));
    });

    test('on stage: their video and audio', () {
      expect(wants('guest-b', visible: {'guest-b'}), (
        audio: true,
        video: true,
      ));
    });

    test('the show audio, but not its video unless on stage', () {
      expect(wants('studio-1', role: 'studio', master: 'studio-1'), (
        audio: true,
        video: false,
      ));
    });

    test('muting the show audio keeps the video', () {
      expect(wants('guest-b', visible: {'guest-b'}, showAudio: false), (
        audio: false,
        video: true,
      ));
    });

    test('the host talkback: always its audio, even with show audio off', () {
      expect(wants('backstage-show', role: 'backstage', showAudio: false), (
        audio: true,
        video: false,
      ));
      // Another show's talkback (or a spoofed name) gets nothing.
      expect(wants('backstage-other', role: 'backstage'), (
        audio: false,
        video: false,
      ));
    });
  });

  group('pre-join form', () {
    testWidgets('name, title, the privacy line and Join', (tester) async {
      final title = TextEditingController(text: 'Director');
      addTearDown(title.dispose);
      var joined = 0;
      await tester.pumpWidget(
        _wrap(
          GuestPreJoinForm(
            eventTitle: 'Late Show',
            preview: const SizedBox(height: 100),
            name: 'Ada',
            titleController: title,
            onJoin: () => joined++,
          ),
        ),
      );
      expect(find.text('Late Show'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Director'), findsOneWidget);
      expect(find.textContaining('Only the host and crew'), findsOneWidget);
      await tester.tap(find.text('Join green room'));
      expect(joined, 1);
    });

    testWidgets('joining disables the button', (tester) async {
      final title = TextEditingController();
      addTearDown(title.dispose);
      await tester.pumpWidget(
        _wrap(
          GuestPreJoinForm(
            preview: const SizedBox(height: 100),
            name: 'Ada',
            titleController: title,
            joining: true,
            error: 'Connection timed out. Try again.',
            onJoin: () {},
          ),
        ),
      );
      expect(find.text('Join green room'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Connection timed out. Try again.'), findsOneWidget);
    });
  });

  testWidgets('countdown shows the seconds left', (tester) async {
    await tester.pumpWidget(_wrap(const GuestCountdown(seconds: 4)));
    expect(find.text('You’re on in'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('control bar: optional buttons and the chat badge', (
    tester,
  ) async {
    var mic = 0;
    await tester.pumpWidget(
      _wrap(
        GuestControlBar(
          micOn: false,
          cameraOn: true,
          onMic: () => mic++,
          onCamera: () {},
          onLeave: () {},
          chatUnread: 3,
          onChat: () {},
        ),
      ),
    );
    expect(find.byTooltip('Unmute mic'), findsOneWidget);
    expect(find.byTooltip('Share screen'), findsNothing);
    expect(find.byTooltip('Mute show audio'), findsNothing);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
    await tester.tap(find.byTooltip('Unmute mic'));
    expect(mic, 1);
  });

  testWidgets('health row reads the connection', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const GuestHealthRow(
          quality: ConnectionQuality.poor,
          micOn: false,
          cameraOn: true,
        ),
      ),
    );
    expect(find.text('Connection poor'), findsOneWidget);
    expect(find.text('Mic muted'), findsOneWidget);
  });

  testWidgets('chat panel sends trimmed text and lists messages', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          height: 400,
          child: GuestChatPanel(
            messages: [
              BackstageMessage(
                from: 'studio',
                name: 'Host',
                text: 'You’re up next',
                at: DateTime(2026),
              ),
            ],
            onSend: sent.add,
          ),
        ),
      ),
    );
    expect(
      find.textContaining('You’re up next', findRichText: true),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), '  ready  ');
    await tester.tap(find.byTooltip('Send'));
    expect(sent, ['ready']);
  });
}
