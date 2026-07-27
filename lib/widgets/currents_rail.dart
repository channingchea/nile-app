import 'package:flutter/material.dart';

import '../services/current_service.dart';
import '../theme.dart';

/// Horizontally scrollable Currents rail for the top of the home feed.
/// First slot is always the caller's own: a plain create entry when they have
/// no live Currents, otherwise their avatar in a volt ring (tap to watch, the
/// + badge to post another). Then one circle per other creator — ringed while
/// unwatched, dimmed once fully watched.
class CurrentsRail extends StatelessWidget {
  const CurrentsRail({
    super.key,
    required this.entries,
    required this.onCreate,
    required this.onTapCreator,
    this.myAvatarUrl,
  });

  final List<CurrentRailEntry> entries;
  final VoidCallback onCreate;
  final void Function(CurrentRailEntry entry) onTapCreator;
  final String? myAvatarUrl;

  static const double _circle = 72;

  @override
  Widget build(BuildContext context) {
    CurrentRailEntry? mine;
    final others = <CurrentRailEntry>[];
    for (final e in entries) {
      if (e.isSelf && mine == null) {
        mine = e;
      } else {
        others.add(e);
      }
    }

    return SizedBox(
      height: 116,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
            NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s8),
        itemCount: others.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: NileSpacing.s12),
        itemBuilder: (_, i) => i == 0
            ? _mySlot(context, mine)
            : _creatorSlot(context, others[i - 1]),
      ),
    );
  }

  /// Avatar circle, wrapped in the volt→azure ring when [ring], else [border].
  Widget _avatar(String? url, {required bool ring, required Color border}) {
    return Container(
      width: _circle,
      height: _circle,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: ring
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [NileColors.volt, NileColors.azure],
              )
            : null,
        border: ring ? null : Border.all(color: border, width: 1.5),
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: NileColors.bgPage,
        ),
        child: CircleAvatar(
          backgroundColor: NileColors.bgRaised,
          backgroundImage:
              url != null ? nileAvatarImage(url, _circle / 2) : null,
          child: url == null
              ? Icon(Icons.person, color: NileColors.txtTertiary, size: 32)
              : null,
        ),
      ),
    );
  }

  /// The caller's own slot. With live Currents it plays them on tap and the +
  /// badge posts another; with none, the whole slot opens the create flow.
  Widget _mySlot(BuildContext context, CurrentRailEntry? mine) {
    return _Slot(
      label: 'Your Current',
      onTap: mine == null ? onCreate : () => onTapCreator(mine),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _avatar(
            mine?.avatarUrl ?? myAvatarUrl,
            ring: mine != null,
            border: NileColors.border,
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCreate,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NileColors.volt,
                  border: Border.all(color: NileColors.bgPage, width: 2),
                ),
                child:
                    const Icon(Icons.add, size: 15, color: NileColors.onVolt),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _creatorSlot(BuildContext context, CurrentRailEntry e) {
    return _Slot(
      label: '@${e.username}',
      dimmed: !e.hasUnwatched,
      onTap: () => onTapCreator(e),
      child: _avatar(
        e.avatarUrl,
        ring: e.hasUnwatched,
        border: NileColors.borderStrong,
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    required this.label,
    required this.child,
    required this.onTap,
    this.dimmed = false,
  });

  final String label;
  final Widget child;
  final VoidCallback onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.6 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            const SizedBox(height: NileSpacing.s4),
            SizedBox(
              width: 80,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: NileTextStyles.caption(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
