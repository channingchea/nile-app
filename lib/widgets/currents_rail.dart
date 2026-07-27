import 'package:flutter/material.dart';

import '../services/current_service.dart';
import '../theme.dart';

/// Horizontally scrollable Currents rail for the top of the home feed.
/// First slot is the caller's "Your Current" create entry; then one circle per
/// creator with live Currents — volt gradient ring while unwatched, dimmed once
/// fully watched.
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

  static const double _circle = 64;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: NileSpacing.s16, vertical: NileSpacing.s8),
        itemCount: entries.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: NileSpacing.s12),
        itemBuilder: (_, i) {
          if (i == 0) return _createSlot(context);
          final e = entries[i - 1];
          return _creatorSlot(context, e);
        },
      ),
    );
  }

  Widget _createSlot(BuildContext context) {
    return _Slot(
      label: 'Your Current',
      onTap: onCreate,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: _circle,
            height: _circle,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: NileColors.bgRaised,
              border: Border.all(color: NileColors.border),
              image: myAvatarUrl != null
                  ? DecorationImage(
                      image: nileAvatarImage(myAvatarUrl!, _circle / 2),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: myAvatarUrl == null
                ? Icon(Icons.person, color: NileColors.txtTertiary, size: 28)
                : null,
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NileColors.volt,
                border: Border.all(color: NileColors.bgPage, width: 2),
              ),
              child: const Icon(Icons.add, size: 14, color: NileColors.onVolt),
            ),
          ),
        ],
      ),
    );
  }

  Widget _creatorSlot(BuildContext context, CurrentRailEntry e) {
    final ring = e.hasUnwatched
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [NileColors.volt, NileColors.azure],
          )
        : null;
    return _Slot(
      label: '@${e.username}',
      dimmed: !e.hasUnwatched,
      onTap: () => onTapCreator(e),
      child: Container(
        width: _circle,
        height: _circle,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: ring,
          border: ring == null
              ? Border.all(color: NileColors.borderStrong, width: 1.5)
              : null,
        ),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: NileColors.bgPage,
          ),
          child: CircleAvatar(
            backgroundColor: NileColors.bgRaised,
            backgroundImage: e.avatarUrl != null
                ? nileAvatarImage(e.avatarUrl!, _circle / 2)
                : null,
            child: e.avatarUrl == null
                ? Icon(Icons.person, color: NileColors.txtTertiary, size: 28)
                : null,
          ),
        ),
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
              width: 72,
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
