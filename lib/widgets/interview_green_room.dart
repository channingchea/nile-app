import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/interview.dart';
import '../theme.dart';
import 'interview_stage.dart';
import 'nile_studio.dart' show NileStudioQuality;

/// Who a green-room row is.
enum GreenRoomKind {
  /// A remote guest (role `guest`).
  guest,

  /// An in-room crew phone (role `camera`).
  camera,

  /// The host's own Studio camera.
  host,
}

/// One row of the Studio's green room column.
@immutable
class GreenRoomEntry {
  const GreenRoomEntry({
    required this.identity,
    required this.name,
    required this.kind,
    required this.status,
    this.title,
    this.avatarUrl,
    this.track,
    this.mirror = false,
    this.level,
    this.micMuted = false,
    this.quality = NileStudioQuality.unknown,
    this.countdown,
    this.onStageFor,
    this.talking = false,
  });

  final String identity;
  final String name;
  final GreenRoomKind kind;

  /// [GuestStatus.invited] = on the list but not connected.
  final GuestStatus status;
  final String? title;
  final String? avatarUrl;
  final VideoTrack? track;
  final bool mirror;

  /// Mic level 0-1, or null when unknown.
  final double? level;
  final bool micMuted;
  final NileStudioQuality quality;

  /// Seconds until they're on ("you're on in 5").
  final int? countdown;
  final Duration? onStageFor;

  /// The host's private line is open to them.
  final bool talking;

  bool get isOnStage => status == GuestStatus.onStage;
  bool get isConnected =>
      status == GuestStatus.greenRoom || status == GuestStatus.onStage;
}

/// What the host can do from the green room. A null callback hides it.
@immutable
class GreenRoomActions {
  const GreenRoomActions({
    this.onBringOn,
    this.onSendBack,
    this.onRemove,
    this.onMute,
    this.onTalk,
    this.onTalkAll,
    this.onInvite,
    this.onFocus,
    this.onAdmit,
    this.onDecline,
  });

  final ValueChanged<GreenRoomEntry>? onBringOn;
  final ValueChanged<GreenRoomEntry>? onSendBack;

  /// Guests only — crew cameras are removed from their own tile menu.
  final ValueChanged<GreenRoomEntry>? onRemove;

  /// (entry, mute?)
  final void Function(GreenRoomEntry entry, bool muted)? onMute;

  /// Opens or closes a private two-way line with one person.
  final ValueChanged<GreenRoomEntry>? onTalk;

  /// Push to talk to everyone waiting: true on press, false on release.
  final ValueChanged<bool>? onTalkAll;
  final VoidCallback? onInvite;

  /// Feature them in Solo / Spotlight.
  final ValueChanged<GreenRoomEntry>? onFocus;

  /// Let a share-link request in, or turn it down.
  final ValueChanged<GreenRoomEntry>? onAdmit;
  final ValueChanged<GreenRoomEntry>? onDecline;
}

/// Interview mode's left column: replaces the Studio's camera list. People
/// asking to join by link first (they need an answer), then on stage (with
/// the 6-person count), who's waiting, and invited guests who haven't joined.
class InterviewGreenRoomColumn extends StatelessWidget {
  const InterviewGreenRoomColumn({
    super.key,
    required this.entries,
    required this.actions,
    this.tileBuilder,
    this.talkingToAll = false,
    this.footer,
  });

  final List<GreenRoomEntry> entries;
  final GreenRoomActions actions;

  /// Replaces a tile's video (Studio Setup's demo guests); null falls back
  /// to the video or avatar.
  final Widget? Function(GreenRoomEntry entry)? tileBuilder;
  final bool talkingToAll;

  /// Pinned under the list (your own mic meter).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final onStage = entries.where((e) => e.isOnStage).toList();
    final waiting = entries
        .where((e) => e.status == GuestStatus.greenRoom)
        .toList();
    final invited = entries
        .where((e) => e.status == GuestStatus.invited)
        .toList();
    final requests = entries
        .where((e) => e.status == GuestStatus.requested)
        .toList();
    final full = onStage.length >= kStageMax;

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s4,
        NileSpacing.s12,
        NileSpacing.s4,
        NileSpacing.s8,
      ),
      child: Text(
        text,
        style: NileTextStyles.labelSm().copyWith(
          color: NileColors.txtTertiary,
          letterSpacing: 1.2,
        ),
      ),
    );

    return Container(
      color: NileColors.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s16,
              NileSpacing.s12,
              NileSpacing.s8,
              NileSpacing.s4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'GREEN ROOM',
                    style: NileTextStyles.labelSm().copyWith(
                      color: NileColors.txtTertiary,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                if (actions.onInvite != null)
                  IconButton(
                    onPressed: actions.onInvite,
                    icon: const Icon(Icons.person_add_alt_1, size: 20),
                    color: NileColors.txtPrimary,
                    tooltip: 'Invite guests',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          if (actions.onTalkAll != null && waiting.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
              child: _HoldToTalk(
                active: talkingToAll,
                onChanged: actions.onTalkAll!,
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(NileSpacing.s16),
                    child: Text(
                      'Invite guests by username or share a link. They wait '
                      'here until you bring them on stage.',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(
                      NileSpacing.s12,
                      0,
                      NileSpacing.s12,
                      NileSpacing.s8,
                    ),
                    children: [
                      if (requests.isNotEmpty)
                        header('ASKING TO JOIN ${requests.length}'),
                      for (final e in requests)
                        GreenRoomRequestTile(
                          key: ValueKey(e.identity),
                          entry: e,
                          actions: actions,
                        ),
                      header('ON STAGE ${onStage.length}/$kStageMax'),
                      if (onStage.isEmpty)
                        Text(
                          'Nobody yet.',
                          style: NileTextStyles.bodySm().copyWith(
                            color: NileColors.txtTertiary,
                          ),
                        ),
                      for (final e in onStage)
                        GreenRoomTile(
                          key: ValueKey(e.identity),
                          entry: e,
                          actions: actions,
                          stageFull: full,
                          tileBuilder: tileBuilder,
                        ),
                      if (waiting.isNotEmpty) header('WAITING'),
                      for (final e in waiting)
                        GreenRoomTile(
                          key: ValueKey(e.identity),
                          entry: e,
                          actions: actions,
                          stageFull: full,
                          tileBuilder: tileBuilder,
                        ),
                      if (invited.isNotEmpty) header('INVITED'),
                      for (final e in invited)
                        GreenRoomTile(
                          key: ValueKey(e.identity),
                          entry: e,
                          actions: actions,
                          stageFull: full,
                          tileBuilder: tileBuilder,
                        ),
                    ],
                  ),
          ),
          if (footer != null) ...[
            Container(height: 1, color: NileColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s16,
                vertical: NileSpacing.s12,
              ),
              child: footer,
            ),
          ],
        ],
      ),
    );
  }
}

class _HoldToTalk extends StatelessWidget {
  const _HoldToTalk({required this.active, required this.onChanged});

  final bool active;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => onChanged(true),
    onPointerUp: (_) => onChanged(false),
    onPointerCancel: (_) => onChanged(false),
    child: Tooltip(
      message: 'Hold to talk to everyone waiting. Viewers can’t hear you.',
      child: AnimatedContainer(
        duration: NileMotion.fast,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? NileColors.volt : NileColors.bgRaised,
          borderRadius: BorderRadius.circular(NileRadius.pill),
          border: Border.all(color: NileColors.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.record_voice_over_outlined,
              size: 16,
              color: active ? NileColors.onVolt : NileColors.txtPrimary,
            ),
            const SizedBox(width: NileSpacing.s6),
            Flexible(
              child: Text(
                active ? 'Talking…' : 'Hold to talk',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.labelSm().copyWith(
                  color: active ? NileColors.onVolt : NileColors.txtPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _GreenRoomMenu { focus, mute, unmute, talk, endTalk, remove }

/// One person in the green room: preview, name and title, mic meter, link
/// health, status, and the host's actions.
class GreenRoomTile extends StatelessWidget {
  const GreenRoomTile({
    super.key,
    required this.entry,
    required this.actions,
    required this.stageFull,
    this.tileBuilder,
  });

  final GreenRoomEntry entry;
  final GreenRoomActions actions;
  final bool stageFull;
  final Widget? Function(GreenRoomEntry entry)? tileBuilder;

  Color get _qualityColor => switch (entry.quality) {
    NileStudioQuality.excellent || NileStudioQuality.good => NileColors.success,
    NileStudioQuality.poor => NileColors.warning,
    NileStudioQuality.lost => NileColors.error,
    NileStudioQuality.unknown => NileColors.txtTertiary,
  };

  String get _status => switch (entry.status) {
    GuestStatus.onStage when entry.countdown != null =>
      'On in ${entry.countdown}…',
    GuestStatus.onStage => 'On stage',
    GuestStatus.greenRoom => 'Waiting',
    GuestStatus.invited => 'Not joined yet',
    GuestStatus.requested => 'Asked to join',
    GuestStatus.removed => 'Removed',
  };

  List<PopupMenuEntry<_GreenRoomMenu>> _menu() {
    final e = entry;
    PopupMenuItem<_GreenRoomMenu> item(
      _GreenRoomMenu v,
      IconData icon,
      String label,
    ) => PopupMenuItem(
      value: v,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: NileSpacing.s12),
          Text(label),
        ],
      ),
    );
    return [
      if (e.isOnStage && actions.onFocus != null)
        item(_GreenRoomMenu.focus, Icons.center_focus_strong, 'Feature'),
      if (e.isConnected && actions.onMute != null)
        e.micMuted
            ? item(_GreenRoomMenu.unmute, Icons.mic, 'Ask to unmute')
            : item(_GreenRoomMenu.mute, Icons.mic_off, 'Mute'),
      if (e.kind == GreenRoomKind.guest &&
          e.status == GuestStatus.greenRoom &&
          actions.onTalk != null)
        e.talking
            ? item(
                _GreenRoomMenu.endTalk,
                Icons.voice_over_off,
                'End private talk',
              )
            : item(
                _GreenRoomMenu.talk,
                Icons.record_voice_over,
                'Talk privately',
              ),
      if (e.kind == GreenRoomKind.guest && actions.onRemove != null)
        item(_GreenRoomMenu.remove, Icons.person_remove, 'Remove from show'),
    ];
  }

  void _onMenu(_GreenRoomMenu v) {
    switch (v) {
      case _GreenRoomMenu.focus:
        actions.onFocus?.call(entry);
      case _GreenRoomMenu.mute:
        actions.onMute?.call(entry, true);
      case _GreenRoomMenu.unmute:
        actions.onMute?.call(entry, false);
      case _GreenRoomMenu.talk:
      case _GreenRoomMenu.endTalk:
        actions.onTalk?.call(entry);
      case _GreenRoomMenu.remove:
        actions.onRemove?.call(entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final menu = _menu();
    final Widget? primary = e.isOnStage
        ? (actions.onSendBack == null
              ? null
              : OutlinedButton(
                  onPressed: () => actions.onSendBack!(e),
                  child: const Text('Send back'),
                ))
        : e.status == GuestStatus.greenRoom && actions.onBringOn != null
        ? Tooltip(
            message: stageFull ? 'The stage is full ($kStageMax)' : '',
            child: FilledButton(
              onPressed: stageFull ? null : () => actions.onBringOn!(e),
              child: const Text('Bring on'),
            ),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: NileSpacing.s8),
      child: Container(
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(
            color: e.talking
                ? NileColors.volt
                : e.isOnStage
                ? NileColors.coral
                : NileColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child:
                        tileBuilder?.call(e) ??
                        (e.track != null
                            ? VideoTrackRenderer(
                                e.track!,
                                fit: VideoViewFit.cover,
                                mirrorMode: e.mirror
                                    ? VideoViewMirrorMode.mirror
                                    : VideoViewMirrorMode.off,
                              )
                            : StageAvatar(
                                name: e.name,
                                avatarUrl: e.avatarUrl,
                                small: true,
                              )),
                  ),
                  if (e.countdown != null)
                    ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Text(
                          '${e.countdown}',
                          style: NileTextStyles.headingLg().copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  if (e.isOnStage && e.onStageFor != null)
                    Positioned(
                      right: NileSpacing.s6,
                      top: NileSpacing.s6,
                      child: Text(
                        formatStageTime(e.onStageFor!),
                        style: NileTextStyles.labelSm().copyWith(
                          color: Colors.white,
                          shadows: const [Shadow(blurRadius: 4)],
                        ),
                      ),
                    ),
                  if (e.kind != GreenRoomKind.guest)
                    Positioned(
                      left: NileSpacing.s6,
                      top: NileSpacing.s6,
                      child: Icon(
                        e.kind == GreenRoomKind.host
                            ? Icons.star_rounded
                            : Icons.phone_iphone,
                        size: 16,
                        color: Colors.white,
                        shadows: const [Shadow(blurRadius: 4)],
                      ),
                    ),
                ],
              ),
            ),
            _MicBar(level: e.micMuted ? 0 : (e.level ?? 0)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s8,
                NileSpacing.s6,
                NileSpacing.s2,
                NileSpacing.s6,
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _qualityColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: NileSpacing.s6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                e.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NileTextStyles.labelMd(),
                              ),
                            ),
                            if (e.micMuted) ...[
                              const SizedBox(width: NileSpacing.s4),
                              Icon(
                                Icons.mic_off,
                                size: 14,
                                color: NileColors.error,
                              ),
                            ],
                          ],
                        ),
                        Text(
                          [
                            if (e.title != null && e.title!.isNotEmpty)
                              e.title!,
                            _status,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NileTextStyles.caption().copyWith(
                            color: NileColors.txtTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (menu.isNotEmpty)
                    PopupMenuButton<_GreenRoomMenu>(
                      tooltip: 'More',
                      icon: Icon(
                        Icons.more_vert,
                        size: 18,
                        color: NileColors.txtSecondary,
                      ),
                      itemBuilder: (_) => menu,
                      onSelected: _onMenu,
                    ),
                ],
              ),
            ),
            if (primary != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s8,
                  0,
                  NileSpacing.s8,
                  NileSpacing.s8,
                ),
                child: primary,
              ),
          ],
        ),
      ),
    );
  }
}

/// Someone who opened the show's share link and is waiting to be let in.
/// They have no picture yet: they only connect once the host says yes.
class GreenRoomRequestTile extends StatelessWidget {
  const GreenRoomRequestTile({
    super.key,
    required this.entry,
    required this.actions,
  });

  final GreenRoomEntry entry;
  final GreenRoomActions actions;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Padding(
      padding: const EdgeInsets.only(bottom: NileSpacing.s8),
      child: Container(
        padding: const EdgeInsets.all(NileSpacing.s8),
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(color: NileColors.volt),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                StageAvatar(name: e.name, avatarUrl: e.avatarUrl, small: true),
                const SizedBox(width: NileSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.labelMd(),
                      ),
                      Text(
                        [
                          if (e.title != null && e.title!.isNotEmpty) e.title!,
                          'Asked to join',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: NileSpacing.s8),
            Row(
              children: [
                if (actions.onDecline != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => actions.onDecline!(e),
                      child: const Text('Decline'),
                    ),
                  ),
                if (actions.onDecline != null && actions.onAdmit != null)
                  const SizedBox(width: NileSpacing.s8),
                if (actions.onAdmit != null)
                  Expanded(
                    child: FilledButton(
                      onPressed: () => actions.onAdmit!(e),
                      child: const Text('Let in'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MicBar extends StatelessWidget {
  const _MicBar({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 3,
    child: FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: level.clamp(0.0, 1.0),
      child: ColoredBox(color: NileColors.volt),
    ),
  );
}
