// Studio master host, phases 1-3 (docs/plans/studio-master-host.md).
//
// The server half (slots, camera count, who takes the master-audio flag) is
// covered by supabase/functions/tests/studio_test.ts. This file covers what the
// app decides on its own:
//   1. Whose audio a viewer plays and which device unmutes — one rule.
//   2. The 30s handover between the Studio and the host's phones.
//   3. The Studio's controls: its own camera toggle, the toolbar, rename.
//   4. "Which camera is this?" — taken slots can't be picked.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/livekit_service.dart';
import 'package:nile_app/services/studio_roles.dart';
import 'package:nile_app/widgets/camera_slot_sheet.dart';
import 'package:nile_app/widgets/nile_studio.dart';

PublisherInfo _p(
  String id,
  String role, {
  bool master = false,
  int? joinedAt,
}) => PublisherInfo(
  identity: id,
  role: role,
  isMasterAudio: master,
  joinedAt: joinedAt,
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('master audio — one rule for viewers and devices', () {
    test('the flagged publisher wins, whatever its role', () {
      final ps = [
        _p('camera-a', NileRole.camera, joinedAt: 1),
        _p('master-audio-ev', NileRole.streamAudio),
        _p('studio-ev', NileRole.studio, master: true),
      ];
      expect(resolveMasterAudio(ps), 'studio-ev');
    });

    test('a flagged camera beats an unflagged Stream Audio', () {
      final ps = [
        _p('master-audio-ev', NileRole.streamAudio),
        _p('camera-b', NileRole.camera, master: true),
      ];
      expect(resolveMasterAudio(ps), 'camera-b');
    });

    test('nobody flagged: Stream Audio, then the earliest camera', () {
      expect(
        resolveMasterAudio([
          _p('camera-a', NileRole.camera, joinedAt: 1),
          _p('master-audio-ev', NileRole.streamAudio),
        ]),
        'master-audio-ev',
      );
      expect(
        resolveMasterAudio([
          _p('camera-late', NileRole.camera, joinedAt: 20),
          _p('camera-early', NileRole.camera, joinedAt: 10),
          _p('studio-ev', NileRole.studio),
        ]),
        'camera-early',
      );
    });

    test('viewers never carry audio, even if their metadata says so', () {
      expect(resolveMasterAudio([_p('viewer-1', 'viewer', master: true)]), isNull);
      expect(resolveMasterAudio(const []), isNull);
    });

    test('a Studio alone, unflagged, is not a fallback source', () {
      expect(resolveMasterAudio([_p('studio-ev', NileRole.studio)]), isNull);
    });

    test('metadata parsing tolerates junk', () {
      expect(parseParticipantMeta(null), isEmpty);
      expect(parseParticipantMeta('not json'), isEmpty);
      expect(parseParticipantMeta('[1,2]'), isEmpty);
      expect(parseParticipantMeta('{"role":"studio"}')['role'], 'studio');
      expect(NileRole.isPublisher('studio'), isTrue);
      expect(NileRole.isPublisher('viewer'), isFalse);
    });
  });

  group('Studio ↔ host phone handover', () {
    test('a Studio arriving takes over at once', () {
      var changes = 0;
      final h = StudioHandover(onChange: () => changes++);
      expect(h.studioInCharge, isFalse);
      h.update(studioPresent: true);
      expect(h.studioInCharge, isTrue);
      expect(changes, 1);
      h.update(studioPresent: true); // repeated reports are not changes
      expect(changes, 1);
      h.dispose();
    });

    test('the phone gets the controls back only after the grace period', () async {
      final changed = Completer<void>();
      late StudioHandover h;
      h = StudioHandover(
        grace: const Duration(milliseconds: 60),
        onChange: () {
          if (!h.studioInCharge && !changed.isCompleted) changed.complete();
        },
      );
      h.update(studioPresent: true);
      h.update(studioPresent: false);
      expect(h.studioInCharge, isTrue, reason: 'still inside the grace');
      await changed.future.timeout(const Duration(seconds: 2));
      expect(h.studioInCharge, isFalse);
      h.dispose();
    });

    test('a Studio that comes back inside the grace never hands over', () async {
      var released = false;
      late StudioHandover h;
      h = StudioHandover(
        grace: const Duration(milliseconds: 40),
        onChange: () => released = released || !h.studioInCharge,
      );
      h.update(studioPresent: true);
      h.update(studioPresent: false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      h.update(studioPresent: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.studioInCharge, isTrue);
      expect(released, isFalse);
      h.dispose();
    });

    test('no Studio ever seen: the phone runs the show as before', () {
      final h = StudioHandover(onChange: () {});
      h.update(studioPresent: false);
      expect(h.studioInCharge, isFalse);
      h.dispose();
    });

    test('reset forgets a pending grace without notifying', () async {
      var changes = 0;
      final h = StudioHandover(
        grace: const Duration(milliseconds: 20),
        onChange: () => changes++,
      );
      h.update(studioPresent: true);
      h.update(studioPresent: false);
      h.reset();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.studioInCharge, isFalse);
      expect(changes, 1); // only the arrival
    });
  });

  group('Studio controls', () {
    NileStudioControlBar bar({
      String? studioCameraLabel,
      bool videoEnabled = true,
      bool showClaim = true,
      List<Widget> toolbar = const [],
    }) => NileStudioControlBar(
      isLive: false,
      isHost: true,
      isMasterAudio: false,
      videoEnabled: videoEnabled,
      onLeave: () {},
      onToggleVideo: () {},
      studioCameraLabel: studioCameraLabel,
      showClaimMasterAudio: showClaim,
      toolbar: toolbar,
    );

    testWidgets('the Studio offers its own camera, off by default', (t) async {
      await t.pumpWidget(
        _host(
          bar(
            studioCameraLabel: 'Use this Mac’s camera',
            videoEnabled: false,
            showClaim: false,
          ),
        ),
      );
      expect(find.text('Use this Mac’s camera'), findsOneWidget);
      expect(find.text('Video On'), findsNothing);
      expect(find.text('Set as Master Audio'), findsNothing);
    });

    testWidgets('a phone camera keeps its old buttons', (t) async {
      await t.pumpWidget(_host(bar()));
      expect(find.text('Set as Master Audio'), findsOneWidget);
      expect(find.text('Use this Mac’s camera'), findsNothing);
    });

    testWidgets('toolbar: target chips and the master-audio menu', (t) async {
      String? picked;
      await t.pumpWidget(
        _host(
          SizedBox(
            width: 1400,
            child: bar(
              studioCameraLabel: 'Use this Mac’s camera',
              showClaim: false,
              toolbar: [
                NileStudioTargetChips(
                  targetLabel: 'Camera 1',
                  allCameras: false,
                  onChanged: (_) {},
                ),
                NileStudioMasterAudioMenu(
                  options: const [
                    NileAudioSourceOption(
                      identity: 'studio-ev',
                      label: 'Studio mic',
                      icon: Icons.desktop_mac_outlined,
                    ),
                    NileAudioSourceOption(
                      identity: 'camera-a',
                      label: 'Camera 1',
                      icon: Icons.videocam_outlined,
                    ),
                  ],
                  current: 'studio-ev',
                  onSelected: (id) => picked = id,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('All cameras'), findsOneWidget);
      expect(find.text('Audio: Studio mic'), findsOneWidget);
      await t.tap(find.text('Audio: Studio mic'));
      await t.pumpAndSettle();
      await t.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Camera 1'),
      );
      await t.pumpAndSettle();
      expect(picked, 'camera-a');
    });
  });

  group('source rows', () {
    testWidgets('renamable rows offer Rename; others do not', (t) async {
      final renamed = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: NileStudio.sourceColumnWidth,
              height: 600,
              child: _SourceListHarness(
                sources: const [
                  NileStudioSource(
                    identity: 'slot:s3',
                    label: 'Camera 3',
                    sublabel: 'Open',
                    slotId: 's3',
                    isRenamable: true,
                  ),
                  NileStudioSource(identity: 'crew:u1', label: '@pat'),
                ],
                onRename: (s) => renamed.add(s.identity),
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Source options'), findsOneWidget);
      await t.tap(find.byTooltip('Source options'));
      await t.pumpAndSettle();
      await t.tap(find.text('Rename camera…'));
      await t.pumpAndSettle();
      expect(renamed, ['slot:s3']);
    });
  });

  group('Which camera is this?', () {
    const mine = 'camera-install-1';
    final slots = CameraSlots(
      slots: const [
        CameraSlot(
          id: 's1',
          slotIndex: 1,
          label: 'Camera 1',
          heldBy: 'camera-other',
          heldByUsername: 'pat',
          heldByDevice: 'iPhone',
        ),
        CameraSlot(id: 's2', slotIndex: 2, label: 'Camera 2', heldBy: mine),
        CameraSlot(id: 's3', slotIndex: 3, label: 'Camera 3'),
      ],
      streamAudioTaken: true,
    );

    test('your own device reconnecting keeps its slot', () {
      expect(slots.slots[0].takenFor(mine), isTrue);
      expect(slots.slots[1].takenFor(mine), isFalse);
      expect(slots.slots[2].takenFor(mine), isFalse);
    });

    testWidgets('taken slots show who has them and cannot be picked', (t) async {
      CameraSlotChoice? choice;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => choice = await showCameraSlotSheet(
                context,
                load: () async => slots,
                myIdentity: mine,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.text('Which camera is this?'), findsOneWidget);
      expect(find.text('In use · @pat · iPhone'), findsOneWidget);
      expect(find.text('In use on another device'), findsOneWidget);

      await t.tap(find.text('Camera 1')); // taken — nothing happens
      await t.pumpAndSettle();
      expect(find.text('Which camera is this?'), findsOneWidget);

      await t.tap(find.text('Camera 3'));
      await t.pumpAndSettle();
      expect(choice?.slot?.id, 's3');
      expect(choice?.streamAudio, isFalse);
    });
  });
}

/// The source list is private to nile_studio.dart; drive it through the
/// public NileStudio with a minimal frame.
class _SourceListHarness extends StatelessWidget {
  const _SourceListHarness({required this.sources, required this.onRename});

  final List<NileStudioSource> sources;
  final ValueChanged<NileStudioSource> onRename;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: const MediaQueryData(size: Size(1400, 900)),
    child: SizedBox(
      width: 1400,
      height: 900,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxWidth: 1400,
        maxHeight: 900,
        child: SizedBox(
          width: 1400,
          height: 900,
          child: NileStudio(
            sources: sources,
            selectedIdentity: null,
            onSelectSource: (_) {},
            selfIdentity: null,
            stats: const NileStudioStats(isLive: false),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
            onRenameSource: onRename,
          ),
        ),
      ),
    ),
  );
}
