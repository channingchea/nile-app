import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;

import '../services/chat_service.dart';
import '../theme.dart';

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
    this.leading,
    this.trailing,
    this.meter,
  });

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

  /// Slots at either end of the stats row. The Studio has no app bar — a
  /// second title strip above a row that already says LIVE would be noise — so
  /// leaving and opening settings live here.
  final Widget? leading;
  final Widget? trailing;

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
        _StudioStatsRow(stats: stats, leading: leading, trailing: trailing),
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
                  selfIdentity: selfIdentity,
                  meter: meter,
                ),
              ),
              const _StudioDivider(),
              Expanded(
                child: _StudioMonitor(
                  selected: selected,
                  self: showSelfPane ? self : null,
                ),
              ),
              if (showChatColumn && chat != null) ...[
                const _StudioDivider(),
                SizedBox(width: chatColumnWidth, child: chat),
              ],
            ],
          ),
        ),
        _StudioControlBar(child: controls),
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

// ── Stats row ────────────────────────────────────────────────────────────────
// One line across the top answering the questions a host asks mid-show without
// wanting to hunt: am I live, how long have I been, how long is left, is anyone
// watching, is my crew ready, whose audio is going out, and is my link healthy.

class _StudioStatsRow extends StatelessWidget {
  const _StudioStatsRow({required this.stats, this.leading, this.trailing});

  final NileStudioStats stats;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final remaining = stats.remaining;
    final urgent = remaining != null && remaining <= const Duration(minutes: 2);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border(bottom: BorderSide(color: NileColors.border)),
      ),
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
              color: stats.readyCount == stats.crewCount
                  ? NileColors.volt
                  : null,
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
          Text(
            label,
            style: NileTextStyles.labelSm().copyWith(color: color),
          ),
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
    this.meter,
  });

  final List<NileStudioSource> sources;
  final String? selectedIdentity;
  final ValueChanged<String> onSelect;
  final String? selfIdentity;
  final Widget? meter;

  @override
  Widget build(BuildContext context) {
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
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      NileSpacing.s12,
                      0,
                      NileSpacing.s12,
                      NileSpacing.s16,
                    ),
                    itemCount: sources.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: NileSpacing.s8),
                    itemBuilder: (context, i) {
                      final s = sources[i];
                      return _SourceTile(
                        source: s,
                        selected: s.identity == selectedIdentity,
                        onTap: () => onSelect(s.identity),
                      );
                    },
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

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final NileStudioSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: source.label,
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
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _VideoPane(source: source, compact: true),
              ),
              const SizedBox(height: NileSpacing.s6),
              Row(
                children: [
                  Icon(
                    source.isScreenShare
                        ? Icons.screen_share_outlined
                        : Icons.videocam_outlined,
                    size: 14,
                    color: NileColors.txtTertiary,
                  ),
                  const SizedBox(width: NileSpacing.s4),
                  Expanded(
                    child: Text(
                      source.label,
                      style: NileTextStyles.labelSm().copyWith(
                        color: NileColors.txtPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (source.isMasterAudio)
                    Tooltip(
                      message: 'Master audio',
                      child: Icon(
                        Icons.album,
                        size: 14,
                        color: NileColors.volt,
                      ),
                    ),
                  if (source.isReady) ...[
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
                ],
              ),
              if (source.sublabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: NileSpacing.s2),
                  child: Text(
                    source.sublabel!,
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
}

// ── Monitor ──────────────────────────────────────────────────────────────────

class _StudioMonitor extends StatelessWidget {
  const _StudioMonitor({required this.selected, required this.self});

  final NileStudioSource? selected;

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
  const _LabelledPane({required this.title, required this.source});

  final String title;
  final NileStudioSource? source;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: _VideoPane(source: source, compact: false),
          ),
        ),
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
  const _VideoPane({required this.source, required this.compact});

  final NileStudioSource? source;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final track = source?.track;
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
// Live chat is an ephemeral Supabase broadcast — nothing is persisted, so there
// is no message on a server for a host to delete. What a host *can* do is stop
// hearing from someone (local, instant, undoable), block them (persisted by
// BlockService, and it applies everywhere in the app, not just this show), and
// report them for review. Those are the three actions here, in that order of
// severity.

/// The Studio's right-hand column.
class NileStudioChat extends StatelessWidget {
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
  });

  /// Newest first — the list renders reversed, matching the phone overlay.
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

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final m in messages)
        if (m.isSystem ||
            !(hiddenSenders.contains(m.senderId) ||
                blockedSenders.contains(m.senderId)))
          m,
    ];

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
                // Flexible, not bare: the column is a fixed 320 pt and the
                // label grows with the count.
                if (hiddenSenders.isNotEmpty)
                  Flexible(
                    child: TextButton(
                      onPressed: onShowAll,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: NileSpacing.s8,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '${hiddenSenders.length} hidden · Show all',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.volt,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NileSpacing.s16,
                    ),
                    child: Text(
                      'Chat is quiet — messages from viewers appear here.',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(
                      NileSpacing.s16,
                      0,
                      NileSpacing.s8,
                      NileSpacing.s16,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _ChatRow(
                      message: visible[i],
                      selfId: selfId,
                      onHide: onHide,
                      onBlock: onBlock,
                      onReport: onReport,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChatRow extends StatefulWidget {
  const _ChatRow({
    required this.message,
    required this.selfId,
    required this.onHide,
    required this.onBlock,
    required this.onReport,
  });

  final ChatMessage message;
  final String? selfId;
  final void Function(ChatMessage message) onHide;
  final void Function(ChatMessage message) onBlock;
  final void Function(ChatMessage message) onReport;

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

enum _ModAction { hide, block, report }

class _ChatRowState extends State<_ChatRow> {
  bool _hovering = false;

  void _run(_ModAction action) {
    switch (action) {
      case _ModAction.hide:
        widget.onHide(widget.message);
      case _ModAction.block:
        widget.onBlock(widget.message);
      case _ModAction.report:
        widget.onReport(widget.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    // System lines are the app talking (a tip landed, someone joined) and mine
    // are mine — neither has anyone to moderate.
    final moderatable =
        !m.isSystem && m.senderId.isNotEmpty && m.senderId != widget.selfId;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s4),
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
                  : Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '@${m.username}  ',
                            style: NileTextStyles.bodySm().copyWith(
                              color: NileColors.volt,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextSpan(
                            text: m.content,
                            style: NileTextStyles.bodySm().copyWith(
                              color: NileColors.txtPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            SizedBox(
              width: 32,
              child: moderatable
                  ? Opacity(
                      opacity: _hovering ? 1 : 0.25,
                      child: PopupMenuButton<_ModAction>(
                        tooltip: 'Moderate @${m.username}',
                        color: NileColors.bgRaised,
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: Icon(
                          Icons.more_horiz,
                          color: NileColors.txtTertiary,
                        ),
                        onSelected: _run,
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: _ModAction.hide,
                            child: Text(
                              'Hide @${m.username} for this show',
                              style: NileTextStyles.bodySm(),
                            ),
                          ),
                          PopupMenuItem(
                            value: _ModAction.block,
                            child: Text(
                              'Block @${m.username}',
                              style: NileTextStyles.bodySm(),
                            ),
                          ),
                          PopupMenuItem(
                            value: _ModAction.report,
                            child: Text(
                              'Report @${m.username}',
                              style: NileTextStyles.bodySm().copyWith(
                                color: NileColors.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
