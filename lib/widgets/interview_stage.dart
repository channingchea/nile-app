import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/interview.dart';
import '../theme.dart';

/// One person on the Interview stage, as every stage view draws them.
@immutable
class StageTile {
  const StageTile({
    required this.identity,
    required this.name,
    this.title,
    this.avatarUrl,
    this.track,
    this.mirror = false,
    this.speaking = false,
    this.muted = false,
    this.onStageFor,
    this.countdown,
    this.isScreenShare = false,
  });

  /// LiveKit identity (a guest, a crew camera, or the Studio).
  final String identity;
  final String name;
  final String? title;
  final String? avatarUrl;

  /// Null while there's no video (camera off, still arriving): the tile shows
  /// the avatar instead, so the layout never jumps.
  final VideoTrack? track;
  final bool mirror;

  /// Active speaker — the tile gets a volt outline when highlighting is on.
  final bool speaking;
  final bool muted;

  /// Time on stage, shown when the view's timers are on (Studio only).
  final Duration? onStageFor;

  /// Seconds until they appear ("you're on in 5"), shown over the tile.
  final int? countdown;
  final bool isScreenShare;
}

/// The Interview stage: everyone on it composed in a 16:9 frame with
/// [stageSlots]. Used by viewers, the guest's preview, the Studio's stage
/// monitor and Studio Setup's rehearsal, so all of them show the same picture.
///
/// [tileBuilder] replaces the video for a tile (Studio Setup's demo guests;
/// null falls back to the video or avatar);
/// name tags, the speaker outline, timers and countdowns are drawn on top
/// either way. [overlay] is drawn over the whole frame (graphics).
class InterviewStageView extends StatelessWidget {
  const InterviewStageView({
    super.key,
    required this.tiles,
    required this.layout,
    this.focusIndex = 0,
    this.showNames = true,
    this.showTimers = false,
    this.highlightSpeaker = true,
    this.tileBuilder,
    this.onTapTile,
    this.overlay,
    this.emptyLabel = 'Nobody on stage yet',
    this.compact = false,
  });

  final List<StageTile> tiles;
  final StageLayout layout;
  final int focusIndex;
  final bool showNames;
  final bool showTimers;
  final bool highlightSpeaker;
  final Widget? Function(StageTile tile)? tileBuilder;
  final ValueChanged<StageTile>? onTapTile;
  final Widget? overlay;
  final String emptyLabel;

  /// Small previews: smaller name tags, no titles.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final slots = stageSlots(layout, tiles.length, focusIndex: focusIndex);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRect(
        child: ColoredBox(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth, h = c.maxHeight;
              return Stack(
                children: [
                  if (tiles.isEmpty)
                    Center(
                      child: Text(
                        emptyLabel,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ),
                  for (final s in slots)
                    Positioned(
                      key: ValueKey(tiles[s.index].identity),
                      left: s.rect.left * w,
                      top: s.rect.top * h,
                      width: s.rect.width * w,
                      height: s.rect.height * h,
                      child: _Tile(
                        tile: tiles[s.index],
                        view: this,
                        small: compact || s.rect.width < 0.3,
                      ),
                    ),
                  ?overlay,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.view, required this.small});

  final StageTile tile;
  final InterviewStageView view;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = tile;
    final media =
        view.tileBuilder?.call(t) ??
        (t.track != null
            ? VideoTrackRenderer(
                t.track!,
                fit: t.isScreenShare
                    ? VideoViewFit.contain
                    : VideoViewFit.cover,
                mirrorMode: t.mirror
                    ? VideoViewMirrorMode.mirror
                    : VideoViewMirrorMode.off,
              )
            : StageAvatar(name: t.name, avatarUrl: t.avatarUrl, small: small));
    final outline = view.highlightSpeaker && t.speaking;
    return GestureDetector(
      onTap: view.onTapTile == null ? null : () => view.onTapTile!(t),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: NileColors.bgRaised, child: media),
          if (view.showNames)
            Positioned(
              left: NileSpacing.s6,
              bottom: NileSpacing.s6,
              right: NileSpacing.s6,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _NameTag(tile: t, small: small),
              ),
            ),
          if (view.showTimers && t.onStageFor != null)
            Positioned(
              right: NileSpacing.s6,
              top: NileSpacing.s6,
              child: _Pill(text: formatStageTime(t.onStageFor!), small: small),
            ),
          if (t.countdown != null)
            ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Text(
                  '${t.countdown}',
                  style:
                      (small
                              ? NileTextStyles.headingMd()
                              : NileTextStyles.displayMd())
                          .copyWith(color: Colors.white),
                ),
              ),
            ),
          IgnorePointer(
            child: AnimatedContainer(
              duration: NileMotion.fast,
              decoration: BoxDecoration(
                border: Border.all(
                  color: outline ? NileColors.volt : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "12:04" — minutes and seconds on stage (hours folded into minutes).
String formatStageTime(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

class _NameTag extends StatelessWidget {
  const _NameTag({required this.tile, required this.small});

  final StageTile tile;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final title = small ? null : tile.title;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? NileSpacing.s6 : NileSpacing.s8,
        vertical: small ? NileSpacing.s2 : NileSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tile.muted) ...[
            Icon(Icons.mic_off, size: small ? 10 : 14, color: NileColors.error),
            const SizedBox(width: NileSpacing.s4),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      (small
                              ? NileTextStyles.caption()
                              : NileTextStyles.labelMd())
                          .copyWith(color: Colors.white),
                ),
                if (title != null && title.isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NileTextStyles.caption().copyWith(
                      color: Colors.white70,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.small});

  final String text;
  final bool small;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s6,
      vertical: NileSpacing.s2,
    ),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Text(
      text,
      style: (small ? NileTextStyles.caption() : NileTextStyles.labelSm())
          .copyWith(color: Colors.white),
    ),
  );
}

/// A person with no video: their avatar, or their initial.
class StageAvatar extends StatelessWidget {
  const StageAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.small = false,
  });

  final String name;
  final String? avatarUrl;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final r = small ? 18.0 : 36.0;
    return Center(
      child: CircleAvatar(
        radius: r,
        backgroundColor: NileColors.bgSurface,
        foregroundImage: avatarUrl != null && avatarUrl!.isNotEmpty
            ? NetworkImage(avatarUrl!)
            : null,
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: (small ? NileTextStyles.labelMd() : NileTextStyles.headingMd())
              .copyWith(color: NileColors.txtSecondary),
        ),
      ),
    );
  }
}

/// Solo / Side by side / Grid / Spotlight, as small icon buttons.
class StageLayoutPicker extends StatelessWidget {
  const StageLayoutPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final StageLayout value;
  final ValueChanged<StageLayout>? onChanged;

  static IconData iconFor(StageLayout l) => switch (l) {
    StageLayout.solo => Icons.crop_square,
    StageLayout.side => Icons.view_column_outlined,
    StageLayout.grid => Icons.grid_view,
    StageLayout.spotlight => Icons.view_quilt_outlined,
  };

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final l in StageLayout.values)
        IconButton(
          tooltip: l.label,
          isSelected: l == value,
          onPressed: onChanged == null
              ? null
              : () {
                  if (l != value) onChanged!(l);
                },
          icon: Icon(iconFor(l)),
          color: NileColors.txtSecondary,
          selectedIcon: Icon(iconFor(l), color: NileColors.volt),
        ),
    ],
  );
}
