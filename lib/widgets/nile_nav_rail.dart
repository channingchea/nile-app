import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/message_service.dart';
import '../services/notification_service.dart';
import '../theme.dart';
import 'nile_destinations.dart';
import 'nile_logo.dart';

/// The desktop left navigation rail — the counterpart to [NileGlassNavBar],
/// which it replaces from the `medium` breakpoint up.
///
/// Two widths, chosen by the window class rather than by a flag the caller has
/// to remember: 214 px with labels at `expanded` and wider, 72 px icon-only
/// between 900 and 1279.
///
/// Unlike the glass bar it does not take a flat list of destinations, because
/// the rail is not a flat list of branches: Currents, Notifications and My
/// Tickets are ordinary routes sitting between them. [NileRailEntry] carries
/// that distinction and the shell decides what a tap means; the rail only
/// reports which slot was hit.
class NileNavRail extends StatefulWidget {
  const NileNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.entries,
    required this.labelled,
    required this.onCreate,
    required this.onSettings,
  }) : assert(entries.length >= 2);

  /// Rail slot to highlight, or `-1` for none — which is what standing on a
  /// route with no row of its own (Profile) looks like.
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NileRailEntry> entries;

  /// Labels + full width when true; icons only when false.
  final bool labelled;

  final VoidCallback onCreate;
  final VoidCallback onSettings;

  static const double expandedWidth = 214;
  static const double collapsedWidth = 72;

  static double widthFor(bool labelled) =>
      labelled ? expandedWidth : collapsedWidth;

  @override
  State<NileNavRail> createState() => _NileNavRailState();
}

class _NileNavRailState extends State<NileNavRail> {
  int _notifications = 0;
  int _messages = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // The rail is always on screen, so it owns the badges the feed's app bar
    // used to show. Two cheap count queries; a minute is well inside how fresh
    // an unread badge needs to be.
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    // Deliberately independent: a failure fetching one count must not blank the
    // other, and neither is worth surfacing to the user.
    try {
      final n = await NotificationService.unreadCount();
      if (mounted && n != _notifications) setState(() => _notifications = n);
    } catch (_) {
      // A failed badge count is not worth surfacing.
    }
    try {
      final n = await MessageService.unreadTotal();
      if (mounted && n != _messages) setState(() => _messages = n);
    } catch (_) {
      // As above.
    }
  }

  int _badgeFor(NileRailBadge kind) => switch (kind) {
    NileRailBadge.none => 0,
    NileRailBadge.notifications => _notifications,
    NileRailBadge.messages => _messages,
  };

  void _tap(int slot, NileRailEntry entry) {
    widget.onDestinationSelected(slot);
    // Opening either list clears it; reflect that now rather than waiting up to
    // a minute for the poll to catch up.
    switch (entry.badge) {
      case NileRailBadge.notifications:
        if (_notifications != 0) setState(() => _notifications = 0);
      case NileRailBadge.messages:
        if (_messages != 0) setState(() => _messages = 0);
      case NileRailBadge.none:
        break;
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
            for (final (i, e) in widget.entries.indexed)
              _RailItem(
                icon: e.destination.icon,
                selectedIcon: e.destination.selectedIcon,
                label: e.destination.label,
                labelled: labelled,
                selected: i == widget.selectedIndex,
                badge: _badgeFor(e.badge),
                onTap: () => _tap(i, e),
              ),
            const Spacer(),
            Divider(color: NileColors.border, height: 1),
            const SizedBox(height: NileSpacing.s8),
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

/// Mark plus wordmark at the top of the rail, matching the splash and login
/// screens. The wordmark is dropped in the 72 px rail rather than scaled into
/// illegibility — [FittedBox] keeps the mark itself inside either width without
/// needing a separate icon-only asset.
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
        child: labelled
            ? Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  NileLogo(size: 'small', height: 26),
                  const SizedBox(width: NileSpacing.s8),
                  Text(
                    'Nile',
                    style: GoogleFonts.syne(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: NileColors.volt,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              )
            : NileLogo(size: 'small', height: 20),
      ),
    ),
  );
}

/// The single primary action, in volt — a labelled pill when there's room, a
/// circular "+" when there isn't.
///
/// Still "Create" rather than the wireframe's "Go Live": hosting is not enabled
/// on macOS until Phase 8, so a Go Live button would dead-end today.
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
          // In the labelled rail the count belongs at the far end of the row,
          // where the eye already is after reading the label. In the icon-only
          // rail there is no far end, so it rides the glyph.
          labelled ? glyph : _Badged(count: badge, child: glyph),
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
            if (badge > 0) _Pill(count: badge),
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
        label: badge > 0 ? '$label, $badge unread' : label,
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

/// Trailing count for the labelled rail.
class _Pill extends StatelessWidget {
  const _Pill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: NileColors.coral,
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Text(
      count > 9 ? '9+' : '$count',
      style: NileTextStyles.caption().copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
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
