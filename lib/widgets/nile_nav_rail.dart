import 'dart:async';

import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../theme.dart';
import 'nile_glass_nav_bar.dart' show NileGlassDestination;
import 'nile_logo.dart';

/// The desktop left navigation rail — the counterpart to [NileGlassNavBar],
/// which it replaces from the `medium` breakpoint up.
///
/// Two widths, chosen by the window class rather than by a flag the caller has
/// to remember: 214 px with labels at `expanded` and wider, 72 px icon-only
/// between 900 and 1279. Its interface is deliberately identical to the glass
/// bar's — `selectedIndex` + `onDestinationSelected` + `destinations` — so the
/// shell swaps one for the other without touching the branch wiring.
class NileNavRail extends StatefulWidget {
  const NileNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.labelled,
    required this.onCreate,
    required this.onNotifications,
    required this.onSettings,
  }) : assert(destinations.length >= 2);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NileGlassDestination> destinations;

  /// Labels + full width when true; icons only when false.
  final bool labelled;

  final VoidCallback onCreate;
  final VoidCallback onNotifications;
  final VoidCallback onSettings;

  static const double expandedWidth = 214;
  static const double collapsedWidth = 72;

  static double widthFor(bool labelled) =>
      labelled ? expandedWidth : collapsedWidth;

  @override
  State<NileNavRail> createState() => _NileNavRailState();
}

class _NileNavRailState extends State<NileNavRail> {
  int _unread = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refreshUnread();
    // The rail is always on screen, so it owns the badge the feed's app bar
    // used to show. Cheap count query; a minute is well inside how fresh a
    // notification badge needs to be.
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _refreshUnread());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refreshUnread() async {
    try {
      final n = await NotificationService.unreadCount();
      if (mounted && n != _unread) setState(() => _unread = n);
    } catch (_) {
      // A failed badge count is not worth surfacing.
    }
  }

  @override
  Widget build(BuildContext context) {
    final labelled = widget.labelled;
    return Container(
      width: NileNavRail.widthFor(labelled),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border(right: BorderSide(color: NileColors.border)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Brand(labelled: labelled),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: labelled ? NileSpacing.s12 : NileSpacing.s16,
              ),
              child: _CreateAction(labelled: labelled, onTap: widget.onCreate),
            ),
            const SizedBox(height: NileSpacing.s16),
            for (final (i, d) in widget.destinations.indexed)
              _RailItem(
                icon: d.icon,
                selectedIcon: d.selectedIcon,
                label: d.label,
                labelled: labelled,
                selected: i == widget.selectedIndex,
                onTap: () => widget.onDestinationSelected(i),
              ),
            const Spacer(),
            Divider(color: NileColors.border, height: 1),
            const SizedBox(height: NileSpacing.s8),
            _RailItem(
              icon: Icons.notifications_outlined,
              selectedIcon: Icons.notifications,
              label: 'Notifications',
              labelled: labelled,
              selected: false,
              badge: _unread,
              onTap: () {
                widget.onNotifications();
                // Opening the list clears it; reflect that without waiting for
                // the poll.
                if (_unread != 0) setState(() => _unread = 0);
              },
            ),
            _RailItem(
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: 'Settings',
              labelled: labelled,
              selected: false,
              onTap: widget.onSettings,
            ),
            const SizedBox(height: NileSpacing.s12),
          ],
        ),
      ),
    );
  }
}

/// Wordmark at the top of the rail. [FittedBox] keeps it inside the 72 px rail
/// without needing a separate icon-only asset.
class _Brand extends StatelessWidget {
  const _Brand({required this.labelled});
  final bool labelled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      labelled ? NileSpacing.s16 : NileSpacing.s8,
      NileSpacing.s24,
      NileSpacing.s16,
      NileSpacing.s24,
    ),
    child: Align(
      alignment: labelled ? Alignment.centerLeft : Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: NileLogo(size: 'small', height: labelled ? 26 : 20),
      ),
    ),
  );
}

/// The single primary action, in volt — a labelled pill when there's room, a
/// circular "+" when there isn't.
class _CreateAction extends StatelessWidget {
  const _CreateAction({required this.labelled, required this.onTap});
  final bool labelled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!labelled) {
      return Center(
        child: Tooltip(
          message: 'Create',
          child: Material(
            color: NileColors.volt,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.add, color: NileColors.onVolt, size: 24),
              ),
            ),
          ),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add, size: 20),
      label: const Text('Create'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
      ),
    );
  }
}

/// One rail row. Mirrors the glass bar's selected treatment — a volt-tinted
/// pill behind the row, never a volt glyph — so the two navs read as the same
/// component at different sizes.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.labelled,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool labelled;
  final bool selected;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final color = selected ? NileColors.txtPrimary : NileColors.txtSecondary;
    final glyph = Icon(selected ? selectedIcon : icon, color: color, size: 24);

    final row = AnimatedContainer(
      duration: NileMotion.fast,
      curve: NileMotion.curve,
      height: 44,
      padding: EdgeInsets.symmetric(
        horizontal: labelled ? NileSpacing.s12 : 0,
      ),
      decoration: BoxDecoration(
        color: selected
            ? NileColors.volt.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Row(
        mainAxisAlignment:
            labelled ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          _Badged(count: badge, child: glyph),
          if (labelled) ...[
            const SizedBox(width: NileSpacing.s12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.labelMd().copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: labelled ? NileSpacing.s12 : NileSpacing.s16,
        vertical: NileSpacing.s2,
      ),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: labelled ? '' : label,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(NileRadius.pill),
            child: row,
          ),
        ),
      ),
    );
  }
}

class _Badged extends StatelessWidget {
  const _Badged({required this.count, required this.child});
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) => count <= 0
      ? child
      : Badge(
          label: Text(count > 9 ? '9+' : '$count'),
          backgroundColor: NileColors.coral,
          child: child,
        );
}
