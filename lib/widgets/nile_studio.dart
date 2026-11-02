import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;

import '../services/camera_status.dart';
import '../services/chat_service.dart';
import '../services/chat_tools_service.dart' show QuickMessage;
import '../services/realsync.dart' show realSyncCapMs;
import 'elements/element_kinds.dart' show ElementInteraction;
import '../services/live_elements.dart';
import '../services/overlay_layout.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'nile_graphics_layer.dart';
import 'nile_link_text.dart';
import 'studio_tile_dialogs.dart';

// ── Studio ───────────────────────────────────────────────────────────────────
// The desktop face of `camera_screen`. The phone screen is one full-bleed
// preview with controls floated over it, which is right for a device you hold
// up at the thing you are filming and wrong for a Mac on a desk that is running
// the whole show. The Studio unpacks that single pane into four:
//
//   sources │ monitor + your own camera │ chat & moderation
//   ────────┴──── live stats across the top, controls across the bottom ───────
//
// It is presentation only. Every piece of state, every LiveKit call and every
// confirm dialog stays in `_CameraScreenState` — the phone layout and this one
// are two views of one state machine, which is the only way they can be
// guaranteed to behave identically.
//
// "Program/preview" in the plan meant an OBS-style pair. Nile has no program
// bus: the replay egress records a room composite and viewers pick their own
// angle, so there is nothing for a host to switch. The monitor is therefore
// *inspection* — whichever feed you want to look at closely — and the second
// pane is always your own camera, the thing you are personally responsible for.

/// One feed the Studio can show: a crew camera, a screen share, or your own.
@immutable
class NileStudioSource {
  const NileStudioSource({
    required this.identity,
    required this.label,
    this.sublabel,
    this.track,
    this.isLocal = false,
    this.isScreenShare = false,
    this.isMasterAudio = false,
    this.isReady = false,
    this.mirror = false,
    this.isRemovable = false,
    this.slotId,
    this.isRenamable = false,
    this.lagMs,
    this.isOffAir = false,
    this.isDefaultAngle = false,
    this.viewers,
    this.level,
    this.health,
    this.statusUnsupported = false,
    this.nudgeAcked = false,
    this.connectionQuality = NileStudioQuality.unknown,
    this.element,
  });

  /// LiveKit participant identity, plus a suffix for a participant's second
  /// (screen-share) feed so the two are distinct rows.
  final String identity;

  final String label;

  /// Camera slot, role, or connection state — whatever the row should say
  /// under the name.
  final String? sublabel;

  /// Null while a track is unsubscribed, muted, or still arriving; the tile
  /// shows a placeholder rather than collapsing, so the roster stays stable.
  final VideoTrack? track;

  final bool isLocal;
  final bool isScreenShare;
  final bool isMasterAudio;
  final bool isReady;
  final bool mirror;

  /// Whether the host may eject this source. False for your own feed, for
  /// roster placeholders (nobody to disconnect), and for the screen-share row —
  /// a share isn't a participant of its own, so removing the operator's camera
  /// row takes their share with it.
  final bool isRemovable;

  /// The camera slot this row is (event_cameras.id) — set for a connected
  /// feed on a slot and for an open slot's placeholder row.
  final String? slotId;

  /// Whether the host may rename this camera from the Studio.
  final bool isRenamable;

  /// RealSync: how far this camera's picture trails the most current one, in
  /// ms. Null when not measured.
  final int? lagMs;

  /// Viewers can't see this angle right now (tile dims, OFF AIR badge).
  final bool isOffAir;

  /// New viewers start here (★).
  final bool isDefaultAngle;

  /// Signed-in viewers on this angle (👁 N). Null = not counted.
  final int? viewers;

  /// The phone's mic level, 0-1, from the status link. Null = no fresh level
  /// ("No signal"); only meaningful when [health] has ever arrived.
  final double? level;

  /// The phone's last health report. Null = none yet.
  final CameraHealth? health;

  /// A connected camera on a build too old to report status.
  final bool statusUnsupported;

  /// The operator just 👍'd a nudge — the tile says "Read" for a few seconds.
  final bool nudgeAcked;

  /// This feed's own connection, from LiveKit.
  final NileStudioQuality connectionQuality;

  /// An element shown as its own angle (phase 4): the tile draws it instead
  /// of video. [slotId] is its angle id (`el:<id>`).
  final LiveElement? element;

  /// An open slot or an absent crew member's row — nobody to talk to.
  bool get isPlaceholder =>
      identity.startsWith('slot:') ||
      identity.startsWith('crew:') ||
      element != null;

  /// A slot-holding camera the show controls (off air, default, order) apply to.
  bool get isAngle => slotId != null && !isScreenShare;
}

/// What the host can do from a source tile. Every callback is optional: null
/// hides its menu item, so the caller decides authority (host vs crew, Studio
/// vs phone) and the tile only decides whether an item applies to that feed.
@immutable
class NileStudioSourceActions {
  const NileStudioSourceActions({
    this.onToggleOffAir,
    this.onSetDefault,
    this.onSendEveryone,
    this.onMakeMasterAudio,
    this.onRemoveGraphic,
    this.onNudge,
    this.onCommand,
    this.onReorder,
    this.onLayers,
  });

  final ValueChanged<NileStudioSource>? onToggleOffAir;
  final ValueChanged<NileStudioSource>? onSetDefault;
  final ValueChanged<NileStudioSource>? onSendEveryone;
  final ValueChanged<NileStudioSource>? onMakeMasterAudio;

  /// A graphic's icon menu on the tile: off this camera, or off every camera.
  final void Function(
    NileStudioSource source,
    LiveGraphic graphic, {
    required bool everywhere,
  })?
  onRemoveGraphic;

  /// Send the operator a nudge (a preset or custom text).
  final void Function(NileStudioSource source, String text)? onNudge;

  /// Remote control: flip, flashlight, zoom, focus/exposure lock.
  final void Function(NileStudioSource source, StudioCommand command)?
  onCommand;

  /// Tiles dragged into a new order: the slot ids, top to bottom.
  final ValueChanged<List<String>>? onReorder;

  /// "Layers…": where this camera's graphics and elements sit.
  final ValueChanged<NileStudioSource>? onLayers;
}

/// Signal strength for the top row. Mapped from LiveKit's `ConnectionQuality`
/// so the widget never imports a room.
enum NileStudioQuality { excellent, good, poor, lost, unknown }

/// Everything the stats row reports. A value type so a widget test can assert
/// what it renders without standing up a LiveKit room.
@immutable
class NileStudioStats {
  const NileStudioStats({
    required this.isLive,
    this.elapsed,
    this.remaining,
    this.autoEnding = false,
    this.viewerCount = 0,
    this.readyCount = 0,
    this.crewCount = 0,
    this.cameraCount = 1,
    this.quality = NileStudioQuality.unknown,
    this.audioSourceLabel,
    this.notRecording = false,
  });

  final bool isLive;

  /// Time since the show actually started. Null in Sound Check.
  final Duration? elapsed;

  /// Time left in the purchased duration, non-null only inside the last ten
  /// minutes — the same window the phone layout shows a pill for.
  final Duration? remaining;

  final bool autoEnding;
  final int viewerCount;
  final int readyCount;
  final int crewCount;

  /// Feeds publishing video right now, your own included.
  final int cameraCount;

  final NileStudioQuality quality;

  /// Who viewers are hearing — the Stream Audio operator, or the camera
  /// holding master audio.
  final String? audioSourceLabel;

  /// Set when Start Show came back saying the replay recording never started.
  /// It gets a permanent chip rather than a toast: a host who misses the
  /// message has no way of finding out until the show is over and there is
  /// nothing to sell, and by then it is unfixable.
  final bool notRecording;

  static String formatClock(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// The Studio itself.
///
/// [showChatColumn] is the shell's `hasContextRail` rule applied here: below
/// 1180 pt the third column would squeeze the monitor past usefulness, so chat
/// falls back to the same floating overlay the phone layout uses.
class NileStudio extends StatelessWidget {
  const NileStudio({
    super.key,
    required this.sources,
    required this.selectedIdentity,
    required this.onSelectSource,
    required this.selfIdentity,
    required this.stats,
    required this.controls,
    required this.showChatColumn,
    this.chat,
    this.banner,
    this.hud,
    this.leading,
    this.trailing,
    this.center,
    this.meter,
    this.onRemoveSource,
    this.onRenameSource,
    this.graphicsFor,
    this.previewFor,
    this.isCued,
    this.overlayFor,
    this.previewOverlayFor,
    this.sourceActions = const NileStudioSourceActions(),
  });

  /// Off air, default angle, nudges, remote controls, reorder…
  final NileStudioSourceActions sourceActions;

  /// Sources in display order: your own camera first, then crew, then shares.
  final List<NileStudioSource> sources;

  /// The feed in the monitor. Falls back to the first source when the selected
  /// one leaves mid-show.
  final String? selectedIdentity;
  final ValueChanged<String> onSelectSource;

  /// Identity of this device's own camera, so the layout can tell "you" from
  /// the crew without a boolean per call site.
  final String? selfIdentity;

  final NileStudioStats stats;

  /// The existing control cluster, built by `camera_screen` so Start Show,
  /// End Stream and every confirm dialog have exactly one implementation.
  final Widget controls;

  final bool showChatColumn;

  /// The moderation column. Required in practice when [showChatColumn] is set.
  final Widget? chat;

  /// The external-mic suggestion strip, when one is showing.
  final Widget? banner;

  /// The element HUD strip, between the monitor and the control bar
  /// (docs/plans/studio-element-hud.md). It sizes itself to nothing when idle.
  final Widget? hud;

  /// Slots at either end of the stats row. The Studio has no app bar — a
  /// second title strip above a row that already says LIVE would be noise — so
  /// leaving and opening settings live here.
  final Widget? leading;
  final Widget? trailing;

  /// Centered in the stats row — the Studio mode switch.
  final Widget? center;

  /// Ejects a source from the room. Null hides the affordance entirely — only
  /// the host gets it, and only on sources marked [NileStudioSource.isRemovable].
  final ValueChanged<NileStudioSource>? onRemoveSource;

  /// Renames a camera. Null hides it; offered on [NileStudioSource.isRenamable].
  final ValueChanged<NileStudioSource>? onRenameSource;

  /// The graphics a viewer of [source] would see right now, drawn over the
  /// monitor so the director sees what goes out. Null draws none.
  final List<LiveGraphic> Function(NileStudioSource source)? graphicsFor;

  /// Cue before air: what the monitor shows for a source — on-air graphics
  /// plus the cued one. Falls back to [graphicsFor].
  final List<LiveGraphic> Function(NileStudioSource source)? previewFor;

  /// The cued graphic would land on this source (CUED badge / outline).
  final bool Function(NileStudioSource source)? isCued;

  /// Live elements and the layer list for [source], on tiles; the monitor uses
  /// [previewOverlayFor] (with cued elements) when given.
  final NileOverlayExtras Function(NileStudioSource source)? overlayFor;
  final NileOverlayExtras Function(NileStudioSource source)? previewOverlayFor;

  /// This device's own audio meter, pinned under the source list. It belongs
  /// beside the roster rather than over the video: it is about the feed you are
  /// responsible for, not the one you happen to be looking at.
  final Widget? meter;

  static const double sourceColumnWidth = 232;
  static const double chatColumnWidth = 320;

  NileStudioSource? get _selected {
    if (sources.isEmpty) return null;
    for (final s in sources) {
      if (s.identity == selectedIdentity) return s;
    }
    return sources.first;
  }

  NileStudioSource? get _self {
    for (final s in sources) {
      if (s.isLocal && !s.isScreenShare) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final self = _self;
    // No point showing your camera twice — when it is already the monitor, the
    // second pane is dead space.
    final showSelfPane = self != null && self.identity != selected?.identity;

    return Column(
      children: [
        _StudioStatsRow(
          stats: stats,
          leading: leading,
          trailing: trailing,
          center: center,
        ),
        ?banner,
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: sourceColumnWidth,
                child: _StudioSourceList(
                  sources: sources,
                  selectedIdentity: selected?.identity,
                  onSelect: onSelectSource,
                  onRemove: onRemoveSource,
                  onRename: onRenameSource,
                  selfIdentity: selfIdentity,
                  meter: meter,
                  actions: sourceActions,
                  graphicsFor: graphicsFor,
                  overlayFor: overlayFor,
                  isCued: isCued,
                ),
              ),
              const _StudioDivider(),
              // The control bar belongs to the monitor column, so sources and
              // chat run the full height beside it.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _StudioMonitor(
                        selected: selected,
                        self: showSelfPane ? self : null,
                        graphicsFor: previewFor ?? graphicsFor,
                        overlayFor: previewOverlayFor ?? overlayFor,
                        isCued: isCued,
                      ),
                    ),
                    ?hud,
                    _StudioControlBar(child: controls),
                  ],
                ),
              ),
              if (showChatColumn && chat != null) ...[
                const _StudioDivider(),
                SizedBox(width: chatColumnWidth, child: chat),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StudioDivider extends StatelessWidget {
  const _StudioDivider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: NileColors.border);
}

/// Stats row with a centered widget: the center is laid out first (at most
/// 60% of the row), then each side gets exactly half of what is left.
class _CenteredBarLayout extends MultiChildLayoutDelegate {
  static const left = 'left', center = 'center', right = 'right';

  @override
  void performLayout(Size size) {
    final mid = layoutChild(
      center,
      BoxConstraints(maxWidth: size.width * 0.6, maxHeight: size.height),
    );
    final side = max(0.0, (size.width - mid.width) / 2 - NileSpacing.s12);
    final sideBox = BoxConstraints.tightFor(width: side, height: size.height);
    final l = layoutChild(left, sideBox.loosen());
    layoutChild(right, sideBox);
    positionChild(left, Offset(0, (size.height - l.height) / 2));
    positionChild(
      center,
      Offset((size.width - mid.width) / 2, (size.height - mid.height) / 2),
    );
    positionChild(right, Offset(size.width - side, 0));
  }

  @override
  bool shouldRelayout(_CenteredBarLayout oldDelegate) => false;
}

// ── Stats row ────────────────────────────────────────────────────────────────
// One line across the top answering the questions a host asks mid-show without
// wanting to hunt: am I live, how long have I been, how long is left, is anyone
// watching, is my crew ready, whose audio is going out, and is my link healthy.

class _StudioStatsRow extends StatelessWidget {
  const _StudioStatsRow({
    required this.stats,
    this.leading,
    this.trailing,
    this.center,
  });

  final NileStudioStats stats;
  final Widget? leading;
  final Widget? trailing;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final remaining = stats.remaining;
    final urgent = remaining != null && remaining <= const Duration(minutes: 2);
    final decoration = BoxDecoration(
      color: NileColors.bgSurface,
      border: Border(bottom: BorderSide(color: NileColors.border)),
    );
    const padding = EdgeInsets.symmetric(horizontal: NileSpacing.s16);

    // With a center widget it sits in the true middle (scaled down if the
    // window is very narrow) and each side scrolls rather than overflow.
    if (center case final mid?) {
      return Container(
        height: 56,
        padding: padding,
        decoration: decoration,
        child: CustomMultiChildLayout(
          delegate: _CenteredBarLayout(),
          children: [
            LayoutId(
              id: _CenteredBarLayout.left,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: NileSpacing.s8),
                    ],
                    _StatusChip(isLive: stats.isLive),
                    ..._statChips(stats, urgent),
                  ],
                ),
              ),
            ),
            LayoutId(
              id: _CenteredBarLayout.center,
              child: FittedBox(fit: BoxFit.scaleDown, child: mid),
            ),
            LayoutId(
              id: _CenteredBarLayout.right,
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _QualityChip(quality: stats.quality),
                      if (trailing != null) ...[
                        const SizedBox(width: NileSpacing.s8),
                        trailing!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 56,
      padding: padding,
      decoration: decoration,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: NileSpacing.s8),
          ],
          _StatusChip(isLive: stats.isLive),
          // The stats scroll rather than overflow. A Mac window can be dragged
          // to 740 pt and a long Stream Audio name is unbounded, so the two
          // things a host must always see — am I live, is my link healthy —
          // stay pinned at the ends and everything between them gives way.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _statChips(stats, urgent),
              ),
            ),
          ),
          const SizedBox(width: NileSpacing.s12),
          _QualityChip(quality: stats.quality),
          if (trailing != null) ...[
            const SizedBox(width: NileSpacing.s8),
            trailing!,
          ],
        ],
      ),
    );
  }

  List<Widget> _statChips(NileStudioStats stats, bool urgent) {
    final remaining = stats.remaining;
    return [
      // First in the row, and in the error colour: this is the one thing
      // here the host can still act on while the show is running.
      if (stats.notRecording) ...[
        const SizedBox(width: NileSpacing.s12),
        _Stat(
          icon: Icons.fiber_smart_record,
          label: 'NOT RECORDING',
          tooltip:
              'The replay recording never started — there will be no '
              'replay to sell for this show',
          color: NileColors.error,
        ),
      ],
      if (stats.elapsed != null) ...[
        const SizedBox(width: NileSpacing.s12),
        _Stat(
          icon: Icons.schedule,
          label: NileStudioStats.formatClock(stats.elapsed!),
          tooltip: 'Time on air',
        ),
      ],
      if (remaining != null) ...[
        const SizedBox(width: NileSpacing.s12),
        _Stat(
          icon: Icons.timer_outlined,
          label: stats.autoEnding
              ? 'Ending stream…'
              : '${NileStudioStats.formatClock(remaining)} left',
          tooltip: 'Time left in the purchased duration',
          color: urgent ? NileColors.coral : NileColors.amber,
        ),
      ],
      if (stats.isLive) ...[
        const SizedBox(width: NileSpacing.s12),
        _Stat(
          icon: Icons.visibility_outlined,
          label: '${stats.viewerCount}',
          tooltip: 'Watching now',
        ),
      ],
      const SizedBox(width: NileSpacing.s12),
      _Stat(
        icon: Icons.videocam_outlined,
        label: '${stats.cameraCount}',
        tooltip: stats.cameraCount == 1 ? 'Camera' : 'Cameras publishing',
      ),
      if (stats.crewCount > 0) ...[
        const SizedBox(width: NileSpacing.s12),
        _Stat(
          icon: Icons.groups_outlined,
          label: '${stats.readyCount}/${stats.crewCount} ready',
          tooltip: 'Crew who have confirmed ready',
          color: stats.readyCount == stats.crewCount ? NileColors.volt : null,
        ),
      ],
      if (stats.audioSourceLabel != null) ...[
        const SizedBox(width: NileSpacing.s12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: _Stat(
            icon: Icons.album,
            label: stats.audioSourceLabel!,
            tooltip: 'Audio viewers are hearing',
          ),
        ),
      ],
    ];
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isLive});

  final bool isLive;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s12,
        vertical: NileSpacing.s6,
      ),
      decoration: BoxDecoration(
        color: isLive ? NileColors.coral : NileColors.volt,
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isLive ? Icons.circle : Icons.tune,
            size: 8,
            color: isLive ? Colors.white : NileColors.onVolt,
          ),
          const SizedBox(width: NileSpacing.s6),
          Text(
            isLive ? 'LIVE' : 'SOUND CHECK',
            style: NileTextStyles.labelSm().copyWith(
              color: isLive ? Colors.white : NileColors.onVolt,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.color,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? NileColors.txtSecondary;
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: tint),
          const SizedBox(width: NileSpacing.s6),
          Flexible(
            child: Text(
              label,
              style: NileTextStyles.labelSm().copyWith(color: tint),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({required this.quality});

  final NileStudioQuality quality;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String label, Color color) = switch (quality) {
      NileStudioQuality.excellent => (
        Icons.signal_cellular_alt,
        'Excellent',
        NileColors.volt,
      ),
      NileStudioQuality.good => (
        Icons.signal_cellular_alt_2_bar,
        'Good',
        NileColors.txtSecondary,
      ),
      NileStudioQuality.poor => (
        Icons.signal_cellular_alt_1_bar,
        'Poor',
        NileColors.amber,
      ),
      NileStudioQuality.lost => (
        Icons.signal_cellular_connected_no_internet_0_bar,
        'Reconnecting',
        NileColors.error,
      ),
      NileStudioQuality.unknown => (
        Icons.signal_cellular_alt,
        'Connection',
        NileColors.txtTertiary,
      ),
    };
    return Tooltip(
      message: 'Upload connection to the stream server',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: NileSpacing.s6),
          Text(label, style: NileTextStyles.labelSm().copyWith(color: color)),
        ],
      ),
    );
  }
}

// ── Sources ──────────────────────────────────────────────────────────────────

class _StudioSourceList extends StatelessWidget {
  const _StudioSourceList({
    required this.sources,
    required this.selectedIdentity,
    required this.onSelect,
    required this.selfIdentity,
    required this.actions,
    this.onRemove,
    this.onRename,
    this.meter,
    this.graphicsFor,
    this.overlayFor,
    this.isCued,
  });

  final List<NileStudioSource> sources;
  final String? selectedIdentity;
  final ValueChanged<String> onSelect;
  final ValueChanged<NileStudioSource>? onRemove;
  final ValueChanged<NileStudioSource>? onRename;
  final String? selfIdentity;
  final Widget? meter;
  final NileStudioSourceActions actions;
  final List<LiveGraphic> Function(NileStudioSource source)? graphicsFor;
  final NileOverlayExtras Function(NileStudioSource source)? overlayFor;
  final bool Function(NileStudioSource source)? isCued;

  /// Slot ids in the order the tiles now show, after dragging [from] to [to].
  static List<String> slotOrderAfter(
    List<NileStudioSource> sources,
    int from,
    int to,
  ) {
    final next = [...sources];
    next.insert(to, next.removeAt(from));
    final seen = <String>{};
    return [
      for (final s in next)
        if (s.isAngle && seen.add(s.slotId!)) s.slotId!,
    ];
  }

  Widget _tile(BuildContext context, int i) {
    final s = sources[i];
    return Padding(
      key: ValueKey(s.identity),
      padding: const EdgeInsets.only(bottom: NileSpacing.s8),
      child: _SourceTile(
        source: s,
        index: i,
        reorderable: actions.onReorder != null && s.isAngle,
        selected: s.identity == selectedIdentity,
        onTap: () => onSelect(s.identity),
        onRemove: s.isRemovable && onRemove != null ? () => onRemove!(s) : null,
        onRename: s.isRenamable && onRename != null ? () => onRename!(s) : null,
        actions: actions,
        graphics: graphicsFor?.call(s) ?? const [],
        extras: overlayFor?.call(s) ?? _noExtras,
        cued: isCued?.call(s) ?? false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final padding = const EdgeInsets.fromLTRB(
      NileSpacing.s12,
      0,
      NileSpacing.s12,
      NileSpacing.s8,
    );
    return Container(
      color: NileColors.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s16,
              NileSpacing.s16,
              NileSpacing.s16,
              NileSpacing.s8,
            ),
            child: Text(
              'SOURCES',
              style: NileTextStyles.labelSm().copyWith(
                color: NileColors.txtTertiary,
                letterSpacing: 1.5,
              ),
            ),
          ),
          Expanded(
            child: sources.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(NileSpacing.s16),
                    child: Text(
                      'No feeds yet.',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  )
                : actions.onReorder == null
                ? ListView.builder(
                    padding: padding,
                    itemCount: sources.length,
                    itemBuilder: _tile,
                  )
                : ReorderableListView.builder(
                    padding: padding,
                    buildDefaultDragHandles: false,
                    itemCount: sources.length,
                    onReorderItem: (from, to) {
                      if (from == to) return;
                      actions.onReorder!(slotOrderAfter(sources, from, to));
                    },
                    itemBuilder: _tile,
                  ),
          ),
          if (meter != null) ...[
            Container(height: 1, color: NileColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s16,
                vertical: NileSpacing.s12,
              ),
              child: meter,
            ),
          ],
        ],
      ),
    );
  }
}

/// Live elements and this camera's layer list, drawn with its graphics
/// (studio live elements, phase 2).
typedef NileOverlayExtras = ({
  List<LiveElement> elements,
  List<LayerEntry> layers,
  ElementInteraction? Function(LiveElement e)? interactionFor,
});

const NileOverlayExtras _noExtras = (
  elements: [],
  layers: [],
  interactionFor: null,
);

/// A short name for a graphic on a tile: its title, else its text, else kind.
String graphicLabel(LiveGraphic g) => switch (g.kind) {
  GraphicKind.chat => 'Chat · @${g.title ?? ''}',
  _ => g.title ?? g.text ?? g.kind.label,
};

IconData graphicKindIcon(GraphicKind k) => switch (k) {
  GraphicKind.lowerThird => Icons.subtitles_outlined,
  GraphicKind.logo => Icons.branding_watermark_outlined,
  GraphicKind.banner => Icons.view_day_outlined,
  GraphicKind.slate => Icons.fullscreen,
  GraphicKind.chat => Icons.chat_bubble_outline,
  GraphicKind.qr => Icons.qr_code_2,
  GraphicKind.sponsor => Icons.handshake_outlined,
};

enum _TileAction {
  rename,
  masterAudio,
  setDefault,
  sendEveryone,
  offAir,
  layers,
  nudge,
  controls,
  remove,
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.index,
    required this.reorderable,
    required this.selected,
    required this.onTap,
    required this.actions,
    required this.graphics,
    this.extras = _noExtras,
    this.cued = false,
    this.onRemove,
    this.onRename,
  });

  final NileStudioSource source;
  final int index;
  final bool cued;
  final bool reorderable;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final VoidCallback? onRename;
  final NileStudioSourceActions actions;
  final List<LiveGraphic> graphics;
  final NileOverlayExtras extras;

  static const _maxIcons = 6;

  bool get _talkable =>
      !source.isLocal && !source.isScreenShare && !source.isPlaceholder;

  List<PopupMenuEntry<_TileAction>> _menu() {
    final s = source;
    PopupMenuItem<_TileAction> item(
      _TileAction a,
      String label, {
      Color? color,
    }) => PopupMenuItem(
      value: a,
      height: 36,
      child: Text(label, style: NileTextStyles.bodySm().copyWith(color: color)),
    );
    final show = [
      if (onRename != null) item(_TileAction.rename, 'Rename camera…'),
      if (actions.onMakeMasterAudio != null &&
          !s.isMasterAudio &&
          !s.isScreenShare &&
          !s.isPlaceholder)
        item(_TileAction.masterAudio, 'Make master audio'),
      if (s.isAngle && actions.onSetDefault != null)
        item(
          _TileAction.setDefault,
          s.isDefaultAngle ? 'Default angle ✓ (clear)' : 'Set as default angle',
        ),
      if (s.isAngle && !s.isOffAir && actions.onSendEveryone != null)
        item(_TileAction.sendEveryone, 'Send everyone here'),
      if (s.isAngle && actions.onToggleOffAir != null)
        item(
          _TileAction.offAir,
          s.isOffAir ? 'Put back on air' : 'Take off air',
        ),
      // An element angle draws no camera graphics, so nothing to lay out.
      if (s.isAngle && s.element == null && actions.onLayers != null)
        item(_TileAction.layers, 'Layers…'),
    ];
    final operator = [
      if (_talkable && actions.onNudge != null)
        item(_TileAction.nudge, 'Nudge operator…'),
      if (_talkable && actions.onCommand != null)
        item(_TileAction.controls, 'Remote controls…'),
    ];
    final danger = [
      if (onRemove != null)
        item(_TileAction.remove, 'Remove from stream', color: NileColors.error),
    ];
    final groups = [show, operator, danger].where((g) => g.isNotEmpty).toList();
    return [
      for (var i = 0; i < groups.length; i++) ...[
        if (i > 0) const PopupMenuDivider(height: 8),
        ...groups[i],
      ],
    ];
  }

  Future<void> _run(BuildContext context, _TileAction a) async {
    final s = source;
    switch (a) {
      case _TileAction.rename:
        onRename?.call();
      case _TileAction.masterAudio:
        actions.onMakeMasterAudio?.call(s);
      case _TileAction.setDefault:
        actions.onSetDefault?.call(s);
      case _TileAction.sendEveryone:
        actions.onSendEveryone?.call(s);
      case _TileAction.offAir:
        actions.onToggleOffAir?.call(s);
      case _TileAction.layers:
        actions.onLayers?.call(s);
      case _TileAction.nudge:
        final text = await showNudgeDialog(context, s.label);
        if (text != null) actions.onNudge?.call(s, text);
      case _TileAction.controls:
        await showRemoteControls(
          context,
          source: s,
          onCommand: (c) => actions.onCommand?.call(s, c),
        );
      case _TileAction.remove:
        onRemove?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = source;
    final menu = _menu();
    return Semantics(
      selected: selected,
      button: true,
      label: s.isOffAir ? '${s.label}, off air' : s.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(NileRadius.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(NileSpacing.s6),
          decoration: BoxDecoration(
            color: selected
                ? NileColors.volt.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(NileRadius.md),
            border: Border.all(
              color: selected ? NileColors.volt : NileColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: _preview()),
              const SizedBox(height: NileSpacing.s6),
              Row(
                children: [
                  if (reorderable)
                    ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Tooltip(
                          message: 'Drag to reorder',
                          child: Icon(
                            Icons.drag_indicator,
                            size: 14,
                            color: NileColors.txtTertiary,
                          ),
                        ),
                      ),
                    )
                  else
                    Icon(
                      s.isScreenShare
                          ? Icons.screen_share_outlined
                          : Icons.videocam_outlined,
                      size: 14,
                      color: NileColors.txtTertiary,
                    ),
                  const SizedBox(width: NileSpacing.s4),
                  Expanded(
                    child: Text(
                      s.label,
                      style: NileTextStyles.labelSm().copyWith(
                        color: NileColors.txtPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (s.lagMs case final lag?) ...[
                    Tooltip(
                      message: lag > realSyncCapMs
                          ? 'Over 1 s behind — RealSync only closes the first '
                                'second of the gap. Check this camera’s connection.'
                          : 'Behind the most current camera',
                      child: Text(
                        '+$lag ms',
                        style: NileTextStyles.caption().copyWith(
                          color: lag > realSyncCapMs
                              ? NileColors.error
                              : lag > 150
                              ? NileColors.amber
                              : NileColors.txtTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: NileSpacing.s4),
                  ],
                  ..._healthIcons(),
                  if (s.isMasterAudio)
                    Tooltip(
                      message: 'Master audio',
                      child: Icon(
                        Icons.album,
                        size: 14,
                        color: NileColors.volt,
                      ),
                    ),
                  if (s.isReady) ...[
                    const SizedBox(width: NileSpacing.s4),
                    Tooltip(
                      message: 'Ready to stream',
                      child: Icon(
                        Icons.check_circle,
                        size: 14,
                        color: NileColors.volt,
                      ),
                    ),
                  ],
                  if (menu.isNotEmpty)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: PopupMenuButton<_TileAction>(
                        padding: EdgeInsets.zero,
                        iconSize: 14,
                        tooltip: 'Source options',
                        color: NileColors.bgSurface,
                        icon: Icon(
                          Icons.more_horiz,
                          color: NileColors.txtTertiary,
                        ),
                        onSelected: (a) => _run(context, a),
                        itemBuilder: (_) => menu,
                      ),
                    ),
                ],
              ),
              if (graphics.isNotEmpty) _graphicIcons(),
              if (s.sublabel != null || s.statusUnsupported)
                Padding(
                  padding: const EdgeInsets.only(top: NileSpacing.s2),
                  child: Text(
                    s.statusUnsupported
                        ? 'Update app for status'
                        : s.health?.resolutionLabel == null
                        ? s.sublabel!
                        : '${s.sublabel ?? ''}${s.sublabel == null ? '' : ' · '}${s.health!.resolutionLabel}',
                    style: NileTextStyles.caption().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    final s = source;
    final badge = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(NileRadius.xs),
    );
    final badgeText = NileTextStyles.caption().copyWith(color: Colors.white);
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            opacity: s.isOffAir ? 0.35 : 1,
            duration: NileMotion.fast,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _VideoPane(
                  source: s,
                  compact: true,
                  interactionFor: extras.interactionFor,
                ),
                // What a viewer of this angle sees, scaled to the tile.
                NileGraphicsLayer(
                  graphics: graphics,
                  elements: extras.elements,
                  layers: extras.layers,
                  interactionFor: extras.interactionFor,
                ),
              ],
            ),
          ),
          if (s.isOffAir)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s6,
                  vertical: NileSpacing.s2,
                ),
                decoration: BoxDecoration(
                  color: NileColors.coral,
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: Text(
                  'OFF AIR',
                  style: NileTextStyles.labelSm().copyWith(
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          if (s.isDefaultAngle)
            Positioned(
              top: NileSpacing.s4,
              left: NileSpacing.s4,
              child: Tooltip(
                message: 'Default angle — new viewers start here',
                child: Container(
                  padding: const EdgeInsets.all(NileSpacing.s2),
                  decoration: badge,
                  child: Icon(Icons.star, size: 12, color: NileColors.amber),
                ),
              ),
            ),
          if (s.viewers case final n?)
            Positioned(
              top: NileSpacing.s4,
              right: NileSpacing.s4,
              child: Tooltip(
                message: n == 1
                    ? '1 viewer on this angle'
                    : '$n viewers on this angle',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s4,
                    vertical: NileSpacing.s2,
                  ),
                  decoration: badge,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.visibility_outlined,
                        size: 11,
                        color: Colors.white,
                      ),
                      const SizedBox(width: NileSpacing.s2),
                      Text('$n', style: badgeText),
                    ],
                  ),
                ),
              ),
            ),
          if (cued)
            const Positioned(
              left: NileSpacing.s4,
              bottom: NileSpacing.s4,
              child: NileCuedChip(),
            ),
          if (s.health != null && _talkable)
            Positioned(
              top: NileSpacing.s4,
              bottom: NileSpacing.s4,
              right: s.viewers == null ? NileSpacing.s4 : null,
              left: s.viewers == null ? null : NileSpacing.s4,
              child: _TileMeter(level: s.level),
            ),
          if (s.nudgeAcked)
            Positioned(
              bottom: NileSpacing.s4,
              left: NileSpacing.s4,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s6,
                  vertical: NileSpacing.s2,
                ),
                decoration: BoxDecoration(
                  color: NileColors.volt,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
                child: Text(
                  '👍 Read',
                  style: NileTextStyles.caption().copyWith(
                    color: NileColors.onVolt,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _healthIcons() {
    final h = source.health;
    if (h == null || !_talkable) return const [];
    Widget icon(IconData i, Color c, String tip) => Padding(
      padding: const EdgeInsets.only(right: NileSpacing.s4),
      child: Tooltip(
        message: tip,
        child: Icon(i, size: 13, color: c),
      ),
    );
    final out = <Widget>[];
    if (h.battery case final b?) {
      out.add(
        icon(
          h.charging
              ? Icons.battery_charging_full
              : b < 15
              ? Icons.battery_alert
              : b < 50
              ? Icons.battery_3_bar
              : Icons.battery_full,
          b < 15 && !h.charging ? NileColors.error : NileColors.txtTertiary,
          'Battery $b%${h.charging ? ' · charging' : ''}',
        ),
      );
    }
    if (h.thermal case final t? when t != ThermalLevel.nominal) {
      out.add(
        icon(
          Icons.thermostat,
          t.isHot ? NileColors.error : NileColors.amber,
          switch (t) {
            ThermalLevel.fair => 'Phone is warm',
            ThermalLevel.serious => 'Phone is hot — it may lower quality',
            _ => 'Phone is overheating',
          },
        ),
      );
    }
    final q = source.connectionQuality;
    if (q == NileStudioQuality.poor || q == NileStudioQuality.lost) {
      out.add(
        icon(
          Icons.signal_cellular_connected_no_internet_4_bar,
          q == NileStudioQuality.lost ? NileColors.error : NileColors.amber,
          q == NileStudioQuality.lost ? 'Connection lost' : 'Poor connection',
        ),
      );
    }
    return out;
  }

  Widget _graphicIcons() {
    final shown = graphics.take(_maxIcons).toList();
    final more = graphics.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(top: NileSpacing.s4),
      child: Wrap(
        spacing: NileSpacing.s2,
        runSpacing: NileSpacing.s2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final g in shown) _graphicChip(g),
          if (more > 0)
            Text(
              '+$more',
              style: NileTextStyles.caption().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _graphicChip(LiveGraphic g) {
    final remove = actions.onRemoveGraphic;
    return SizedBox(
      width: 24,
      height: 20,
      child: PopupMenuButton<bool>(
        tooltip: graphicLabel(g),
        padding: EdgeInsets.zero,
        enabled: remove != null,
        color: NileColors.bgSurface,
        style: IconButton.styleFrom(
          minimumSize: const Size(24, 20),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: NileColors.bgRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NileRadius.xs),
          ),
        ),
        icon: Icon(graphicKindIcon(g.kind), size: 12, color: NileColors.volt),
        onSelected: (everywhere) =>
            remove?.call(source, g, everywhere: everywhere),
        itemBuilder: (_) => [
          PopupMenuItem<bool>(
            enabled: false,
            height: 32,
            child: Text(
              graphicLabel(g),
              style: NileTextStyles.labelSm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
          // A screen share isn't a camera slot: what's on it is the
          // all-cameras set, so the only thing to do is take it off all.
          if (source.isAngle)
            PopupMenuItem<bool>(
              value: false,
              height: 36,
              child: Text(
                'Remove from this camera',
                style: NileTextStyles.bodySm(),
              ),
            ),
          PopupMenuItem<bool>(
            value: true,
            height: 36,
            child: Text(
              'Remove from all cameras',
              style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// A slim vertical level bar on a camera tile. Visual only — the Studio can't
/// listen to a single camera. Greys with "No signal" when the phone stops
/// sending levels.
class _TileMeter extends StatelessWidget {
  const _TileMeter({required this.level});

  final double? level;

  @override
  Widget build(BuildContext context) {
    final l = level;
    final bar = Container(
      width: 4,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.bottomCenter,
      child: l == null
          ? null
          : FractionallySizedBox(
              heightFactor: l.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: l > 0.9
                      ? NileColors.error
                      : l > 0.7
                      ? NileColors.amber
                      : NileColors.success,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
    );
    return Tooltip(
      message: l == null ? 'No signal' : 'Mic level',
      child: l == null ? Opacity(opacity: 0.5, child: bar) : bar,
    );
  }
}

// ── Monitor ──────────────────────────────────────────────────────────────────

class _StudioMonitor extends StatelessWidget {
  const _StudioMonitor({
    required this.selected,
    required this.self,
    this.graphicsFor,
    this.overlayFor,
    this.isCued,
  });

  final NileStudioSource? selected;
  final List<LiveGraphic> Function(NileStudioSource source)? graphicsFor;
  final NileOverlayExtras Function(NileStudioSource source)? overlayFor;
  final bool Function(NileStudioSource source)? isCued;

  /// Null when your own camera is already the monitor.
  final NileStudioSource? self;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NileColors.bgPage,
      padding: const EdgeInsets.all(NileSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _LabelledPane(
              title: selected == null
                  ? 'MONITOR'
                  : 'MONITOR · ${selected!.label}',
              source: selected,
              graphics: selected == null
                  ? const []
                  : graphicsFor?.call(selected!) ?? const [],
              extras: selected == null
                  ? _noExtras
                  : overlayFor?.call(selected!) ?? _noExtras,
              cued: selected != null && (isCued?.call(selected!) ?? false),
            ),
          ),
          if (self != null) ...[
            const SizedBox(height: NileSpacing.s12),
            SizedBox(
              height: 160,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _LabelledPane(
                    title: 'YOUR CAMERA',
                    source: self,
                    graphics: graphicsFor?.call(self!) ?? const [],
                    extras: overlayFor?.call(self!) ?? _noExtras,
                    cued: isCued?.call(self!) ?? false,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LabelledPane extends StatelessWidget {
  const _LabelledPane({
    required this.title,
    required this.source,
    this.graphics = const [],
    this.extras = _noExtras,
    this.cued = false,
  });

  final String title;
  final NileStudioSource? source;
  final List<LiveGraphic> graphics;
  final NileOverlayExtras extras;

  /// Showing a cued graphic viewers don't see yet: volt outline + CUED.
  final bool cued;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _VideoPane(
                  source: source,
                  compact: false,
                  interactionFor: extras.interactionFor,
                ),
                NileGraphicsLayer(
                  graphics: graphics,
                  elements: extras.elements,
                  layers: extras.layers,
                  interactionFor: extras.interactionFor,
                ),
              ],
            ),
          ),
        ),
        if (cued) ...[
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: NileColors.volt, width: 2),
                  borderRadius: BorderRadius.circular(NileRadius.md),
                ),
              ),
            ),
          ),
          const Positioned(
            top: NileSpacing.s8,
            right: NileSpacing.s8,
            child: NileCuedChip(),
          ),
        ],
        Positioned(
          top: NileSpacing.s8,
          left: NileSpacing.s8,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s8,
              vertical: NileSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
            child: Text(
              title,
              style: NileTextStyles.labelSm().copyWith(
                color: Colors.white,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A feed, or an honest placeholder saying why there isn't one.
class _VideoPane extends StatelessWidget {
  const _VideoPane({
    required this.source,
    required this.compact,
    this.interactionFor,
  });

  final NileStudioSource? source;
  final bool compact;

  /// Totals (and, in Studio Preview, votes) for an element shown as its own
  /// angle.
  final ElementInteraction? Function(LiveElement e)? interactionFor;

  @override
  Widget build(BuildContext context) {
    final track = source?.track;
    final element = source?.element;
    if (element != null) {
      return NileElementAngle(
        element: element,
        interaction: interactionFor?.call(element),
      );
    }
    return Container(
      color: Colors.black,
      child: track != null
          ? VideoTrackRenderer(
              track,
              // Letterbox rather than crop: a director checking framing needs
              // the whole frame, not a filled rectangle.
              fit: VideoViewFit.contain,
              mirrorMode: source!.mirror
                  ? VideoViewMirrorMode.mirror
                  : VideoViewMirrorMode.off,
            )
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.videocam_off,
                    size: compact ? 20 : 48,
                    color: NileColors.txtTertiary,
                  ),
                  if (!compact) ...[
                    const SizedBox(height: NileSpacing.s8),
                    Text(
                      source == null ? 'No feed selected' : 'No video',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

// ── Controls ─────────────────────────────────────────────────────────────────

class _StudioControlBar extends StatelessWidget {
  const _StudioControlBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s16,
        vertical: NileSpacing.s12,
      ),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border(top: BorderSide(color: NileColors.border)),
      ),
      child: SafeArea(top: false, child: child),
    );
  }
}

// ── Chat & moderation ────────────────────────────────────────────────────────
// Five actions, in ascending order of who they affect.
//
// Hide and Block change only what THIS host sees: hide is local and undoable,
// block is persisted by BlockService and applies everywhere in the app. They
// are labelled "for me" for that reason. Until #16 they were the only levers
// there were, which meant a host could believe they had dealt with a troll the
// whole room could still see.
//
// Remove and Ban change what EVERYONE sees. They go through the `live-chat`
// function against the message record added in migration 0107 — Remove
// soft-deletes one line, Ban bars the sender from this show, wipes what they
// already said and disconnects them. Report sends it to the review queue with
// the message text attached as evidence.

/// The Studio's right-hand column: pinned message, filter chips, the chat
/// itself (holding still while you scroll back), and the host's composer.
class NileStudioChat extends StatefulWidget {
  const NileStudioChat({
    super.key,
    required this.messages,
    required this.hiddenSenders,
    required this.blockedSenders,
    required this.selfId,
    required this.onHide,
    required this.onShowAll,
    required this.onBlock,
    required this.onReport,
    this.onRemove,
    this.onBan,
    this.onSettings,
    this.restrictionLabel,
    this.onSend,
    this.quickMessages = const [],
    this.onEditQuickMessages,
    this.pinned,
    this.onPin,
    this.onUnpin,
    this.onShowOnScreen,
    this.onShowOnScreenOptions,
    this.onRelease,
  });

  /// Newest first — the list renders reversed, matching the phone overlay.
  /// Lines the host's blocked words held back ([ChatMessage.filtered]) are
  /// drawn greyed with "Show anyway".
  final List<ChatMessage> messages;

  /// Sender ids muted for this session only — "Show all" clears these.
  final Set<String> hiddenSenders;

  /// Sender ids blocked outright. Filtered the same way but never restored
  /// here: unblocking is a deliberate act, and it lives in Settings.
  final Set<String> blockedSenders;

  /// The signed-in user's id, passed in rather than read from the Supabase
  /// singleton. `ChatMessage.isMine` reaches into that global, which would make
  /// this panel untestable and couple a layout widget to auth state.
  final String? selfId;

  final void Function(ChatMessage message) onHide;
  final VoidCallback onShowAll;
  final void Function(ChatMessage message) onBlock;
  final void Function(ChatMessage message) onReport;

  /// Room-wide moderation. Null when the viewer of this panel may not moderate
  /// — the host always may, assigned crew only when the host turned crew
  /// moderation on for this show. Same shape as `onRemoveSource`: the caller
  /// decides authority, the widget only decides whether to draw the item.
  final void Function(ChatMessage message)? onRemove;
  final void Function(ChatMessage message)? onBan;

  /// Opens the host's chat controls. Host-only, so null for everyone else.
  final VoidCallback? onSettings;

  /// Set when the host has narrowed the room — "Slow mode · 10s",
  /// "Followers only". Shown in the header because a throttled room looks
  /// exactly like a quiet one, and a host who forgot they turned it on will
  /// otherwise read the silence as the chat being broken.
  final String? restrictionLabel;

  /// Sends a message as this user. Returns an error to show under the field,
  /// or null when it went. Null hides the composer.
  final Future<String?> Function(String text)? onSend;

  /// The ⚡ menu: picking one fills the field, Enter sends it.
  final List<QuickMessage> quickMessages;
  final VoidCallback? onEditQuickMessages;

  /// The pinned message, drawn above the chat.
  final PinnedMessage? pinned;
  final void Function(ChatMessage message)? onPin;
  final VoidCallback? onUnpin;

  /// "Show on screen": the message as a graphic on every camera for 10 s.
  /// [onShowOnScreenOptions] opens the cameras/timer choice instead.
  final void Function(ChatMessage message)? onShowOnScreen;
  final void Function(ChatMessage message)? onShowOnScreenOptions;

  /// "Show anyway" on a line the blocked words held back.
  final void Function(ChatMessage message)? onRelease;

  @override
  State<NileStudioChat> createState() => _NileStudioChatState();
}

class _NileStudioChatState extends State<NileStudioChat> {
  final _scroll = ScrollController();
  final _field = TextEditingController();
  final _focus = FocusNode();
  ChatFilter _filter = ChatFilter.all;
  String? _sendError;
  bool _sending = false;

  /// While scrolled back, the newest message at the moment of pausing. The
  /// list shows only it and older, so new arrivals don't move what you're
  /// reading; the "↓ N new" chip jumps back.
  ChatMessage? _anchor;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final off = _scroll.offset;
    if (_anchor == null && off > 40) {
      final first = _visible(widget.messages).firstOrNull;
      if (first != null) setState(() => _anchor = first);
    } else if (_anchor != null && off < 8) {
      setState(() => _anchor = null);
    }
  }

  void _jumpToNewest() {
    setState(() => _anchor = null);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: NileMotion.base, curve: NileMotion.curve);
    }
  }

  List<ChatMessage> _visible(List<ChatMessage> all) => [
    for (final m in all)
      if ((m.isSystem ||
              !(widget.hiddenSenders.contains(m.senderId) ||
                  widget.blockedSenders.contains(m.senderId))) &&
          _filter.matches(m))
        m,
  ];

  Future<void> _send() async {
    final text = _field.text.trim();
    final send = widget.onSend;
    if (text.isEmpty || send == null || _sending) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    final error = await send(text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sendError = error;
      if (error == null) _field.clear();
    });
    _focus.requestFocus();
    if (error == null) _jumpToNewest();
  }

  @override
  Widget build(BuildContext context) {
    final all = _visible(widget.messages);
    // Paused: everything from the anchor down. If the anchor has gone (it was
    // removed), there is nothing to hold still for.
    final anchorAt = _anchor == null
        ? -1
        : all.indexWhere((m) => identical(m, _anchor));
    final paused = anchorAt >= 0;
    final shown = paused ? all.sublist(anchorAt) : all;
    final unseen = paused ? anchorAt : 0;

    return Container(
      color: NileColors.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          if (widget.restrictionLabel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s16,
                0,
                NileSpacing.s16,
                NileSpacing.s8,
              ),
              child: Text(
                widget.restrictionLabel!,
                style: NileTextStyles.caption().copyWith(
                  color: NileColors.volt,
                ),
              ),
            ),
          if (widget.pinned case final pin?)
            _PinnedBar(pinned: pin, onUnpin: widget.onUnpin),
          _filters(),
          Expanded(
            child: Stack(
              children: [
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NileSpacing.s16,
                    ),
                    child: Text(
                      _filter == ChatFilter.all
                          ? 'Chat is quiet — messages from viewers appear here.'
                          : 'Nothing matches “${_filter.label}” yet.',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  )
                else
                  ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(
                      NileSpacing.s16,
                      0,
                      NileSpacing.s8,
                      NileSpacing.s8,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _ChatRow(
                      key: ObjectKey(shown[i]),
                      message: shown[i],
                      selfId: widget.selfId,
                      onHide: widget.onHide,
                      onBlock: widget.onBlock,
                      onReport: widget.onReport,
                      onRemove: widget.onRemove,
                      onBan: widget.onBan,
                      onPin: widget.onPin,
                      onShowOnScreen: widget.onShowOnScreen,
                      onShowOnScreenOptions: widget.onShowOnScreenOptions,
                      onRelease: widget.onRelease,
                    ),
                  ),
                if (paused)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: NileSpacing.s8,
                    child: Center(
                      child: ActionChip(
                        onPressed: _jumpToNewest,
                        backgroundColor: NileColors.volt,
                        side: BorderSide.none,
                        avatar: const Icon(
                          Icons.arrow_downward,
                          size: 14,
                          color: NileColors.onVolt,
                        ),
                        label: Text(
                          unseen == 0
                              ? 'Back to newest'
                              : unseen == 1
                              ? '1 new message'
                              : '$unseen new messages',
                          style: NileTextStyles.labelSm().copyWith(
                            color: NileColors.onVolt,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.onSend != null) _composer(),
        ],
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s16,
      NileSpacing.s16,
      NileSpacing.s16,
      NileSpacing.s8,
    ),
    child: Row(
      children: [
        Text(
          'CHAT',
          style: NileTextStyles.labelSm().copyWith(
            color: NileColors.txtTertiary,
            letterSpacing: 1.5,
          ),
        ),
        const Spacer(),
        // Flexible, not bare: the column is a fixed 320 pt and the label grows
        // with the count.
        if (widget.hiddenSenders.isNotEmpty)
          Flexible(
            child: TextButton(
              onPressed: widget.onShowAll,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                '${widget.hiddenSenders.length} hidden · Show all',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.caption().copyWith(
                  color: NileColors.volt,
                ),
              ),
            ),
          ),
        if (widget.onSettings != null)
          IconButton(
            onPressed: widget.onSettings,
            tooltip: 'Chat settings',
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: Icon(
              Icons.tune,
              color: widget.restrictionLabel != null
                  ? NileColors.volt
                  : NileColors.txtTertiary,
            ),
          ),
      ],
    ),
  );

  Widget _filters() => SizedBox(
    height: 30,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
      children: [
        for (final f in ChatFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: NileSpacing.s4),
            child: ChoiceChip(
              label: Text(f.label),
              selected: _filter == f,
              onSelected: (_) => setState(() {
                _filter = f;
                _anchor = null;
              }),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              labelStyle: NileTextStyles.caption().copyWith(
                color: _filter == f
                    ? NileColors.onVolt
                    : NileColors.txtSecondary,
              ),
              selectedColor: NileColors.volt,
              backgroundColor: NileColors.bgRaised,
              side: BorderSide.none,
              labelPadding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s4,
              ),
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4),
            ),
          ),
      ],
    ),
  );

  Widget _composer() => Container(
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s12,
      NileSpacing.s8,
      NileSpacing.s12,
      NileSpacing.s12,
    ),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: NileColors.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (widget.quickMessages.isNotEmpty ||
                widget.onEditQuickMessages != null)
              PopupMenuButton<Object>(
                tooltip: 'Quick messages',
                color: NileColors.bgRaised,
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: Icon(Icons.bolt, color: NileColors.volt),
                onSelected: (v) {
                  if (v is QuickMessage) {
                    _field.text = v.body;
                    _field.selection = TextSelection.collapsed(
                      offset: v.body.length,
                    );
                    _focus.requestFocus();
                  } else {
                    widget.onEditQuickMessages?.call();
                  }
                },
                itemBuilder: (_) => [
                  for (final q in widget.quickMessages)
                    PopupMenuItem<Object>(
                      value: q,
                      child: Text(
                        q.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.bodySm(),
                      ),
                    ),
                  if (widget.quickMessages.isEmpty)
                    PopupMenuItem<Object>(
                      enabled: false,
                      child: Text(
                        'No quick messages yet',
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ),
                  if (widget.onEditQuickMessages != null) ...[
                    const PopupMenuDivider(),
                    PopupMenuItem<Object>(
                      value: 'edit',
                      child: Text(
                        'Edit quick messages…',
                        style: NileTextStyles.bodySm(),
                      ),
                    ),
                  ],
                ],
              ),
            Expanded(
              child: TextField(
                controller: _field,
                focusNode: _focus,
                maxLength: ChatService.maxMessageLength,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: NileTextStyles.bodySm(),
                decoration: InputDecoration(
                  hintText: 'Message the chat…',
                  counterText: '',
                  isDense: true,
                  filled: true,
                  fillColor: NileColors.bgRaised,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s12,
                    vertical: NileSpacing.s8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(NileRadius.pill),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: _sending ? null : _send,
              tooltip: 'Send',
              iconSize: 18,
              icon: Icon(Icons.send, color: NileColors.volt),
            ),
          ],
        ),
        if (_sendError != null)
          Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s4),
            child: Text(
              _sendError!,
              style: NileTextStyles.caption().copyWith(color: NileColors.error),
            ),
          ),
      ],
    ),
  );
}

class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.pinned, this.onUnpin});

  final PinnedMessage pinned;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(
      NileSpacing.s12,
      0,
      NileSpacing.s12,
      NileSpacing.s8,
    ),
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s8,
      NileSpacing.s6,
      NileSpacing.s4,
      NileSpacing.s6,
    ),
    decoration: BoxDecoration(
      color: NileColors.bgRaised,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      border: Border.all(color: NileColors.volt.withValues(alpha: 0.4)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.push_pin, size: 14, color: NileColors.volt),
        ),
        const SizedBox(width: NileSpacing.s6),
        Expanded(
          child: NileLinkText(
            pinned.body,
            linkify: pinned.mayLink,
            maxLines: 3,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtPrimary,
            ),
            prefix: TextSpan(
              text: '@${pinned.username}  ',
              style: TextStyle(
                color: nileChatNameColor(
                  pinned.senderId,
                  isHost: pinned.senderRole == 'host',
                ),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (onUnpin != null)
          TextButton(
            onPressed: onUnpin,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Unpin',
              style: NileTextStyles.caption().copyWith(color: NileColors.volt),
            ),
          ),
      ],
    ),
  );
}

class _ChatRow extends StatefulWidget {
  const _ChatRow({
    super.key,
    required this.message,
    required this.selfId,
    required this.onHide,
    required this.onBlock,
    required this.onReport,
    this.onRemove,
    this.onBan,
    this.onPin,
    this.onShowOnScreen,
    this.onShowOnScreenOptions,
    this.onRelease,
  });

  final ChatMessage message;
  final String? selfId;
  final void Function(ChatMessage message) onHide;
  final void Function(ChatMessage message) onBlock;
  final void Function(ChatMessage message) onReport;
  final void Function(ChatMessage message)? onRemove;
  final void Function(ChatMessage message)? onBan;
  final void Function(ChatMessage message)? onPin;
  final void Function(ChatMessage message)? onShowOnScreen;
  final void Function(ChatMessage message)? onShowOnScreenOptions;
  final void Function(ChatMessage message)? onRelease;

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

enum _RowAction {
  pin,
  showOnScreen,
  showOnScreenOptions,
  remove,
  ban,
  hide,
  block,
  report,
}

class _ChatRowState extends State<_ChatRow> {
  bool _hovering = false;

  void _run(_RowAction action) {
    final m = widget.message;
    switch (action) {
      case _RowAction.pin:
        widget.onPin?.call(m);
      case _RowAction.showOnScreen:
        widget.onShowOnScreen?.call(m);
      case _RowAction.showOnScreenOptions:
        widget.onShowOnScreenOptions?.call(m);
      case _RowAction.remove:
        widget.onRemove?.call(m);
      case _RowAction.ban:
        widget.onBan?.call(m);
      case _RowAction.hide:
        widget.onHide(m);
      case _RowAction.block:
        widget.onBlock(m);
      case _RowAction.report:
        widget.onReport(m);
    }
  }

  PopupMenuItem<_RowAction> _item(
    _RowAction value,
    String label, {
    Color? color,
  }) => PopupMenuItem(
    value: value,
    height: 36,
    child: Text(label, style: NileTextStyles.bodySm().copyWith(color: color)),
  );

  List<PopupMenuEntry<_RowAction>> _items() {
    final m = widget.message;
    final w = widget;
    // System lines are the app talking (a tip landed) and mine are mine —
    // neither has anyone to moderate. Both can still be pinned and shown.
    final moderatable =
        !m.isSystem && m.senderId.isNotEmpty && m.senderId != w.selfId;
    final show = <PopupMenuEntry<_RowAction>>[
      if (w.onPin != null && !m.filtered) _item(_RowAction.pin, 'Pin message'),
      if (w.onShowOnScreen != null && !m.isSystem && !m.filtered)
        _item(_RowAction.showOnScreen, 'Show on screen'),
      if (w.onShowOnScreenOptions != null && !m.isSystem && !m.filtered)
        _item(
          _RowAction.showOnScreenOptions,
          'Show on screen — cameras & timer…',
        ),
    ];
    final room = <PopupMenuEntry<_RowAction>>[
      // Remove needs a message id, and a line broadcast by a client that
      // predates #16 has none — rather than offer an item that would quietly
      // do nothing, drop it. Ban still reaches those lines (it clears by
      // sender).
      if (moderatable && w.onRemove != null && m.id != null)
        _item(_RowAction.remove, 'Remove this message'),
      if (moderatable && w.onBan != null)
        _item(
          _RowAction.ban,
          'Ban @${m.username} from this show',
          color: NileColors.error,
        ),
    ];
    // Below the line: only what this host sees. The labels say so.
    final mine = <PopupMenuEntry<_RowAction>>[
      if (moderatable) ...[
        _item(_RowAction.hide, 'Hide @${m.username} for me'),
        _item(_RowAction.block, 'Block @${m.username} for me'),
        _item(
          _RowAction.report,
          m.id != null ? 'Report this message' : 'Report @${m.username}',
          color: NileColors.error,
        ),
      ],
    ];
    final groups = [show, room, mine].where((g) => g.isNotEmpty).toList();
    return [
      for (var i = 0; i < groups.length; i++) ...[
        if (i > 0) const PopupMenuDivider(height: 8),
        ...groups[i],
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final items = _items();
    final body = NileTextStyles.bodySm().copyWith(
      color: m.filtered ? NileColors.txtTertiary : NileColors.txtPrimary,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: m.isSystem
                  ? Text(
                      m.content,
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.volt,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        NileLinkText(
                          m.content,
                          linkify: m.mayLink && !m.filtered,
                          style: body,
                          prefix: TextSpan(
                            children: [
                              if (m.firstTime)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      right: NileSpacing.s4,
                                    ),
                                    child: Tooltip(
                                      message:
                                          'First time chatting in your shows',
                                      child: Icon(
                                        Icons.waving_hand_outlined,
                                        size: 12,
                                        color: NileColors.amber,
                                      ),
                                    ),
                                  ),
                                ),
                              TextSpan(
                                text: '@${m.username}  ',
                                style: TextStyle(
                                  color: m.filtered
                                      ? NileColors.txtTertiary
                                      : nileChatNameColor(
                                          m.senderId,
                                          isHost: m.isHost,
                                        ),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (m.filtered)
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Hidden by your blocked words',
                                style: NileTextStyles.caption().copyWith(
                                  color: NileColors.txtTertiary,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                              if (widget.onRelease != null && m.id != null)
                                TextButton(
                                  onPressed: () => widget.onRelease!(m),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: NileSpacing.s6,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: Text(
                                    'Show anyway',
                                    style: NileTextStyles.caption().copyWith(
                                      color: NileColors.volt,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
            ),
            const SizedBox(width: NileSpacing.s4),
            // A fixed 20 pt box: PopupMenuButton's default 48 pt hit area is
            // what made every row tall.
            SizedBox(
              width: 20,
              height: 20,
              child: items.isEmpty
                  ? null
                  : Opacity(
                      opacity: _hovering ? 1 : 0.25,
                      child: PopupMenuButton<_RowAction>(
                        tooltip: m.isSystem
                            ? 'Message options'
                            : 'Options for @${m.username}',
                        color: NileColors.bgRaised,
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(20, 20),
                          maximumSize: const Size(20, 20),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(
                          Icons.more_horiz,
                          color: NileColors.txtTertiary,
                        ),
                        onSelected: _run,
                        itemBuilder: (_) => items,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Control bar ──────────────────────────────────────────────────────────────
// The buttons along the bottom of the Studio. Presentation only, like the rest
// of this file: `camera_screen` and Studio Preview each pass their own handlers,
// which is what lets the preview show the real button set without being able
// to run a show. A null handler disables its button; flags decide what shows.

class NileStudioControlBar extends StatelessWidget {
  const NileStudioControlBar({
    super.key,
    required this.isLive,
    required this.isHost,
    required this.isMasterAudio,
    required this.videoEnabled,
    required this.onLeave,
    this.leaveLabel = 'Leave',
    this.leaveIcon = Icons.logout,
    this.showChatToggle = false,
    this.chatVisible = true,
    this.onToggleChat,
    this.cameraControl,
    this.showScreenShare = false,
    this.isSharingScreen = false,
    this.onToggleScreenShare,
    this.onToggleVideo,
    this.onClaimMasterAudio,
    this.onViewAsViewer,
    this.onStartShow,
    this.isReady = false,
    this.onToggleReady,
    this.onEndStream,
    this.studioCameraLabel,
    this.showClaimMasterAudio = true,
    this.toolbar = const [],
  });

  /// False means Sound Check — the bar is only ever shown in one of the two.
  final bool isLive;
  final bool isHost;
  final bool isMasterAudio;
  final bool videoEnabled;

  final VoidCallback onLeave;
  final String leaveLabel;
  final IconData leaveIcon;

  /// The chat toggle is only offered when chat has no column of its own.
  final bool showChatToggle;
  final bool chatVisible;
  final VoidCallback? onToggleChat;

  /// Camera picker (desktop/iPad) or flip button (phone). Null hides it.
  final Widget? cameraControl;

  final bool showScreenShare;
  final bool isSharingScreen;
  final VoidCallback? onToggleScreenShare;

  final VoidCallback? onToggleVideo;
  final VoidCallback? onClaimMasterAudio;
  final VoidCallback? onViewAsViewer;
  final VoidCallback? onStartShow;
  final bool isReady;
  final VoidCallback? onToggleReady;
  final VoidCallback? onEndStream;

  /// The Studio's own webcam is off by default and turned on by choice, so
  /// it gets a camera toggle of its own ("Use this Mac's camera") instead of
  /// the master-audio-only Video Off button. Null for a camera device.
  final String? studioCameraLabel;

  /// The phone-style "Set as Master Audio" button. The Studio uses its
  /// master-audio menu in [toolbar] instead.
  final bool showClaimMasterAudio;

  /// Show tools — target chips, rename, master audio — between the device
  /// controls and the show controls. Empty for a camera device.
  final List<Widget> toolbar;

  @override
  Widget build(BuildContext context) {
    final soundCheck = !isLive;
    final studioCam = studioCameraLabel;

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: NileSpacing.s12,
      runSpacing: NileSpacing.s8,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: NileSpacing.s8,
          children: [
            if (showChatToggle) ...[
              NileStudioIconButton(
                onPressed: onToggleChat,
                tooltip: chatVisible ? 'Hide chat' : 'Show chat',
                icon: chatVisible
                    ? Icons.chat_bubble
                    : Icons.chat_bubble_outline,
                active: chatVisible,
              ),
              const SizedBox(width: NileSpacing.s8),
            ],
            if (cameraControl != null && videoEnabled) ...[
              cameraControl!,
              const SizedBox(width: NileSpacing.s8),
            ],
            if (showScreenShare) ...[
              NileStudioIconButton(
                onPressed: onToggleScreenShare,
                tooltip: isSharingScreen
                    ? 'Stop sharing screen'
                    : 'Share screen',
                icon: isSharingScreen
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                active: isSharingScreen,
              ),
              const SizedBox(width: NileSpacing.s8),
            ],
            // Video off is master-audio only: a camera that isn't carrying the
            // sound has nothing left to contribute with its lens covered. A
            // camera that is already off (started that way from a saved
            // setting) always gets the button back, or it could never turn on.
            if (studioCam != null)
              OutlinedButton.icon(
                onPressed: onToggleVideo,
                icon: Icon(videoEnabled ? Icons.videocam_off : Icons.videocam),
                label: Text(videoEnabled ? 'Camera Off' : studioCam),
                style: _outlined(
                  NileColors.txtPrimary,
                  NileColors.borderStrong,
                ),
              )
            else if (isMasterAudio || !videoEnabled)
              OutlinedButton.icon(
                onPressed: onToggleVideo,
                icon: Icon(videoEnabled ? Icons.videocam_off : Icons.videocam),
                label: Text(videoEnabled ? 'Video Off' : 'Video On'),
                style: _outlined(
                  NileColors.txtPrimary,
                  NileColors.borderStrong,
                ),
              ),
            if (showClaimMasterAudio && !isMasterAudio && soundCheck) ...[
              if (!videoEnabled) const SizedBox(width: NileSpacing.s8),
              OutlinedButton.icon(
                onPressed: onClaimMasterAudio,
                icon: const Icon(Icons.album, size: 16),
                label: const Text('Set as Master Audio'),
                style: _outlined(
                  NileColors.txtPrimary,
                  NileColors.borderStrong,
                ),
              ),
            ],
          ],
        ),
        if (toolbar.isNotEmpty)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: NileSpacing.s8,
            children: [
              for (var i = 0; i < toolbar.length; i++) ...[
                if (i > 0) const SizedBox(width: NileSpacing.s8),
                toolbar[i],
              ],
            ],
          ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: NileSpacing.s8,
          children: [
            if (soundCheck && isHost) ...[
              OutlinedButton.icon(
                onPressed: onViewAsViewer,
                icon: const Icon(Icons.headphones),
                label: const Text('View as Viewer'),
                style: _outlined(NileColors.volt, NileColors.volt),
              ),
              const SizedBox(width: NileSpacing.s12),
              FilledButton.icon(
                onPressed: onStartShow,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Show'),
                style: FilledButton.styleFrom(
                  backgroundColor: NileColors.coral,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ),
              ),
              const SizedBox(width: NileSpacing.s12),
            ],
            if (soundCheck && !isHost) ...[
              if (isReady)
                FilledButton.icon(
                  onPressed: onToggleReady,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Ready'),
                  style: FilledButton.styleFrom(
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                    shape: const StadiumBorder(),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: onToggleReady,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Ready to Stream'),
                  style: _outlined(NileColors.volt, NileColors.volt),
                ),
              const SizedBox(width: NileSpacing.s12),
            ],
            if (isLive && isHost) ...[
              OutlinedButton.icon(
                onPressed: onEndStream,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('End Stream'),
                style: _outlined(NileColors.error, NileColors.error),
              ),
              const SizedBox(width: NileSpacing.s12),
            ],
            OutlinedButton.icon(
              onPressed: onLeave,
              icon: Icon(leaveIcon),
              label: Text(leaveLabel),
              style: _outlined(NileColors.txtPrimary, NileColors.border),
            ),
          ],
        ),
      ],
    );
  }

  static ButtonStyle _outlined(Color fg, Color border) =>
      OutlinedButton.styleFrom(
        foregroundColor: fg,
        side: BorderSide(color: border),
        shape: const StadiumBorder(),
      );
}

/// Round icon button used along the Studio's control bar.
class NileStudioIconButton extends StatelessWidget {
  const NileStudioIconButton({
    super.key,
    required this.onPressed,
    required this.tooltip,
    required this.icon,
    this.active = false,
  });

  final VoidCallback? onPressed;
  final String tooltip;
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      color: active ? Colors.white : NileColors.txtPrimary,
      style: IconButton.styleFrom(
        backgroundColor: active ? NileColors.coral : NileColors.bgRaised,
      ),
    );
  }
}

/// Device menu for iPad/macOS: every attached camera plus a "Default" entry,
/// the active one checked. [onSelected] gets null for the default.
class NileCameraPickerButton extends StatelessWidget {
  const NileCameraPickerButton({
    super.key,
    required this.devices,
    required this.selectedId,
    required this.onSelected,
  });

  final List<MediaDevice> devices;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Choose camera',
      // PopupMenuButton swallows null selections, so '' stands in for default.
      onSelected: (id) => onSelected(id.isEmpty ? null : id),
      color: NileColors.bgSurface,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: '',
          checked: selectedId == null,
          child: Text('Default camera', style: NileTextStyles.bodyMd()),
        ),
        for (final d in devices)
          CheckedPopupMenuItem<String>(
            value: d.deviceId,
            checked: selectedId == d.deviceId,
            child: Text(
              d.label.isNotEmpty ? d.label : 'Camera',
              style: NileTextStyles.bodyMd(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      icon: const Icon(Icons.cameraswitch_outlined),
      iconColor: NileColors.txtPrimary,
      style: IconButton.styleFrom(
        backgroundColor: NileColors.bgSurface.withValues(alpha: 0.8),
        padding: const EdgeInsets.all(NileSpacing.s12),
      ),
    );
  }
}

// ── Studio toolbar ───────────────────────────────────────────────────────────
// Show tools that act on the room rather than on this device. The target chips
// say what the tools act on — the selected camera, or every camera at once
// (graphics, phase 5) — so the host never has to guess.

class NileAudioSourceOption {
  const NileAudioSourceOption({
    required this.identity,
    required this.label,
    required this.icon,
  });

  final String identity;
  final String label;
  final IconData icon;
}

/// "Audio: Studio mic ▾" — who carries the show's sound, current one checked.
class NileStudioMasterAudioMenu extends StatelessWidget {
  const NileStudioMasterAudioMenu({
    super.key,
    required this.options,
    required this.current,
    required this.onSelected,
  });

  final List<NileAudioSourceOption> options;
  final String? current;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final label = options
        .where((o) => o.identity == current)
        .map((o) => o.label)
        .firstOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Master audio',
      onSelected: onSelected,
      color: NileColors.bgSurface,
      itemBuilder: (_) => [
        for (final o in options)
          CheckedPopupMenuItem<String>(
            value: o.identity,
            checked: o.identity == current,
            child: Text(
              o.label,
              style: NileTextStyles.bodyMd(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      child: _ToolbarPill(
        icon: Icons.album,
        label: 'Audio: ${label ?? 'none'}',
      ),
    );
  }
}

/// The Studio's audio input — a USB mixer or interface instead of the
/// built-in mic. Shown while the Studio carries the show audio.
class NileStudioMicMenu extends StatelessWidget {
  const NileStudioMicMenu({
    super.key,
    required this.devices,
    required this.selectedId,
    required this.onSelected,
  });

  final List<MediaDevice> devices;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final current = devices
        .where((d) => d.deviceId == selectedId)
        .map((d) => d.label)
        .firstOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Audio input',
      // PopupMenuButton swallows null selections, so '' stands in for default.
      onSelected: (id) => onSelected(id.isEmpty ? null : id),
      color: NileColors.bgSurface,
      itemBuilder: (_) => [
        CheckedPopupMenuItem<String>(
          value: '',
          checked: selectedId == null,
          child: Text('Default input', style: NileTextStyles.bodyMd()),
        ),
        for (final d in devices)
          CheckedPopupMenuItem<String>(
            value: d.deviceId,
            checked: selectedId == d.deviceId,
            child: Text(
              d.label.isNotEmpty ? d.label : 'Microphone',
              style: NileTextStyles.bodyMd(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      child: _ToolbarPill(
        icon: Icons.settings_input_component_outlined,
        label: current == null || current.isEmpty ? 'Default input' : current,
      ),
    );
  }
}

class _ToolbarPill extends StatelessWidget {
  const _ToolbarPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 200),
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s12,
      vertical: NileSpacing.s8,
    ),
    decoration: BoxDecoration(
      color: NileColors.bgRaised,
      borderRadius: BorderRadius.circular(NileRadius.pill),
      border: Border.all(color: NileColors.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: NileColors.txtPrimary),
        const SizedBox(width: NileSpacing.s6),
        Flexible(
          child: Text(
            label,
            style: NileTextStyles.labelSm().copyWith(
              color: NileColors.txtPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Icon(Icons.arrow_drop_down, size: 18, color: NileColors.txtTertiary),
      ],
    ),
  );
}

// ── Cue before air ───────────────────────────────────────────────────────────

/// "CUED" — a graphic waiting for Apply, seen only in the Studio.
class NileCuedChip extends StatelessWidget {
  const NileCuedChip({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s6,
      vertical: NileSpacing.s2,
    ),
    decoration: BoxDecoration(
      color: NileColors.volt,
      borderRadius: BorderRadius.circular(NileRadius.xs),
    ),
    child: Text(
      'CUED',
      style: NileTextStyles.labelSm().copyWith(
        color: NileColors.onVolt,
        letterSpacing: 1.2,
      ),
    ),
  );
}

/// The Studio's cue strip (under the stats row): what is cued — one graphic
/// or several — and Apply / Clear. Enter and Esc do the same.
class NileStudioCueBar extends StatelessWidget {
  const NileStudioCueBar({
    super.key,
    required this.name,
    required this.targets,
    required this.onTake,
    required this.onClear,
    this.count = 1,
    this.busy = false,
  });

  /// One graphic's name, or "3 graphics".
  final String name;

  /// One graphic: "All cameras", "Cam 1, Cam 3"…; several: their names.
  final String targets;

  /// How many are cued — they all go on air with one Apply.
  final int count;
  final VoidCallback onTake;
  final VoidCallback onClear;
  final bool busy;

  @override
  Widget build(BuildContext context) => Container(
    color: NileColors.bgRaised,
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s16,
      vertical: NileSpacing.s8,
    ),
    child: Row(
      children: [
        const NileCuedChip(),
        const SizedBox(width: NileSpacing.s12),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: name, style: NileTextStyles.labelLg()),
                TextSpan(
                  text: count == 1 ? '  →  $targets' : '  ·  $targets',
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: busy ? null : onClear,
          child: Text(count == 1 ? 'Clear (Esc)' : 'Clear all (Esc)'),
        ),
        const SizedBox(width: NileSpacing.s8),
        FilledButton.icon(
          onPressed: busy ? null : onTake,
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.onVolt,
          ),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(count == 1 ? 'Apply (Enter)' : 'Apply all (Enter)'),
        ),
      ],
    ),
  );
}
