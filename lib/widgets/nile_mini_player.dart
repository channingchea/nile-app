import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../router.dart';
import '../services/mini_player.dart';
import '../theme.dart';
import 'nile_glass_nav_bar.dart';

/// Wraps the whole app so the docked player survives route changes.
///
/// It has to live above the router — detail screens are siblings of the tab
/// shell and cover it completely, so anything rendered inside the shell would
/// vanish the moment you opened an event. Installed once, in `main.dart`.
class NileMiniPlayerHost extends StatelessWidget {
  const NileMiniPlayerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        // Listens rather than rebuilding the app: an idle dock costs one
        // AnimatedBuilder tick, and `child` above is never rebuilt by it.
        AnimatedBuilder(
          animation: MiniPlayer.instance,
          builder: (context, _) => MiniPlayer.instance.isActive
              ? const _DockOverlay()
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Gives the dock an `Overlay` of its own.
///
/// The host sits above the router, so nothing here inherits the Navigator's
/// overlay — and `Tooltip` (and any future menu or snack bar) throws
/// "No Overlay widget found" without one, painting an error box over whatever
/// the dock is sitting on.
class _DockOverlay extends StatefulWidget {
  const _DockOverlay();

  @override
  State<_DockOverlay> createState() => _DockOverlayState();
}

class _DockOverlayState extends State<_DockOverlay> {
  // Built once: `initialEntries` is read only on the first mount.
  // The entry goes down with the Overlay that holds it — disposing it here
  // would fire while it is still mounted, which asserts.
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => const _Dock());

  @override
  Widget build(BuildContext context) =>
      Positioned.fill(child: Overlay(initialEntries: [_entry]));
}

class _Dock extends StatelessWidget {
  const _Dock();

  static const double _width = 320;

  @override
  Widget build(BuildContext context) {
    final player = MiniPlayer.instance;
    final controller = player.controller;
    if (controller == null) return const SizedBox.shrink();

    // Clears the glass nav bar on phones; a plain margin on desktop, where
    // there is no bottom bar to avoid.
    final compact = NileBreakpoints.of(context).isCompact;
    final bottom = compact
        ? NileGlassNavBar.reservedHeight +
              MediaQuery.of(context).padding.bottom +
              NileSpacing.s8
        : NileSpacing.s24;

    return Positioned(
      right: NileSpacing.s24,
      bottom: bottom,
      child: Material(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.md),
        clipBehavior: Clip.antiAlias,
        elevation: 12,
        shadowColor: const Color(0x66000000),
        child: Container(
          width: _width,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NileRadius.md),
            border: Border.all(color: NileColors.borderStrong, width: 0.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onTap: () => _expand(player.eventId),
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
              VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: EdgeInsets.zero,
                colors: VideoProgressColors(
                  playedColor: NileColors.volt,
                  bufferedColor: NileColors.borderStrong,
                  backgroundColor: NileColors.bgRaised,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s12,
                  NileSpacing.s8,
                  NileSpacing.s4,
                  NileSpacing.s8,
                ),
                child: Row(
                  children: [
                    // Rebuilds on every position tick, so the play/pause glyph
                    // stays honest even when playback ends on its own.
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller,
                      builder: (_, value, _) => _IconButton(
                        icon: value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow_rounded,
                        tooltip: value.isPlaying ? 'Pause' : 'Play',
                        onTap: player.togglePlay,
                      ),
                    ),
                    const SizedBox(width: NileSpacing.s8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            player.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NileTextStyles.labelSm().copyWith(
                              color: NileColors.txtPrimary,
                              letterSpacing: 0,
                            ),
                          ),
                          if (player.subtitle != null)
                            Text(
                              player.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NileTextStyles.caption(),
                            ),
                        ],
                      ),
                    ),
                    _IconButton(
                      icon: Icons.open_in_full,
                      tooltip: 'Expand',
                      onTap: () => _expand(player.eventId),
                    ),
                    _IconButton(
                      icon: Icons.close,
                      tooltip: 'Close',
                      onTap: player.close,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Reopens the full replay screen, which reclaims this controller on the way
  /// in — playback continues rather than restarting.
  void _expand(String? eventId) {
    if (eventId == null) return;
    nileRouter.push(NileRoutes.eventReplay(eventId));
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.pill),
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s6),
        child: Icon(icon, size: 20, color: NileColors.txtSecondary),
      ),
    ),
  );
}
