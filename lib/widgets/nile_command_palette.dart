import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../router.dart';
import '../services/event_service.dart';
import '../services/platform_support.dart';
import '../services/profile_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import 'official_badge.dart';

/// The ⌘K command palette: one field that jumps to any destination, event or
/// person without leaving the page.
///
/// Static commands match locally and appear instantly; events and people are
/// fetched debounced, so typing never fires a request per keystroke. Results
/// are keyboard-first — ↑/↓ move, Enter opens, Esc closes — because the palette
/// only ever opens from a keystroke in the first place.
class NileCommandPalette extends StatefulWidget {
  const NileCommandPalette._();

  /// Guards against ⌘K stacking a second palette on top of the first.
  static bool _open = false;
  static bool get isOpen => _open;

  static Future<void> show(BuildContext context) async {
    if (_open) return;
    _open = true;
    try {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.45),
        builder: (_) => const NileCommandPalette._(),
      );
    } finally {
      _open = false;
    }
  }

  @override
  State<NileCommandPalette> createState() => _NileCommandPaletteState();
}

/// One row in the palette. [subtitle] is the secondary line; [trailing] is a
/// short right-aligned hint like "Live" or a follower count.
class _Entry {
  _Entry({
    required this.icon,
    required this.title,
    required this.onOpen,
    this.subtitle,
    this.trailing,
    this.avatarUrl,
    this.official = false,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;
  final String? avatarUrl;
  final bool official;
  final Color? accent;
  final VoidCallback onOpen;
}

/// A destination that doesn't need a network round-trip. [keywords] widen what
/// the row matches beyond its visible label ("dm" finding Messages).
class _Command {
  const _Command(this.icon, this.label, this.location, {this.keywords = ''});
  final IconData icon;
  final String label;
  final String location;
  final String keywords;
}

const _commands = <_Command>[
  _Command(Icons.home_outlined, 'Home', NileRoutes.feed, keywords: 'feed'),
  _Command(Icons.calendar_month_outlined, 'Schedule', NileRoutes.schedule, keywords: 'calendar week upcoming coming up whats on'),
  _Command(Icons.search_outlined, 'Discover', '/discover', keywords: 'browse explore'),
  _Command(Icons.send_outlined, 'Messages', NileRoutes.messages, keywords: 'dm inbox chat'),
  _Command(Icons.person_outline, 'Profile', '/profile', keywords: 'me my account'),
  _Command(Icons.notifications_outlined, 'Notifications', NileRoutes.notifications, keywords: 'alerts activity'),
  _Command(Icons.bolt_outlined, 'Currents', NileRoutes.currents, keywords: 'shorts video'),
  _Command(Icons.edit_outlined, 'Create post', NileRoutes.createPost, keywords: 'new write'),
  _Command(Icons.add_circle_outline, 'Create event', NileRoutes.createEvent, keywords: 'new show schedule go live'),
  // Filtered out below on platforms without video_thumbnail (macOS).
  _Command(Icons.bolt, 'Create Current', NileRoutes.createCurrent, keywords: 'new short video'),
  _Command(Icons.confirmation_number_outlined, 'My tickets', NileRoutes.settingsTickets, keywords: 'orders'),
  _Command(Icons.payments_outlined, 'Payouts', NileRoutes.settingsPayouts, keywords: 'earnings money stripe'),
  _Command(Icons.trending_up, 'Boost a performance', NileRoutes.boost, keywords: 'promote ad advertise'),
  _Command(Icons.settings_outlined, 'Settings', NileRoutes.settings, keywords: 'preferences account'),
  _Command(Icons.palette_outlined, 'Appearance', NileRoutes.settingsAppearance, keywords: 'theme dark light'),
];

class _NileCommandPaletteState extends State<NileCommandPalette> {
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  Timer? _debounce;
  int _selected = 0;

  /// Bumped on every query change; a response tagged with a stale token is
  /// dropped, so a slow early request can't overwrite a fast later one.
  int _token = 0;
  bool _searching = false;

  List<Event> _events = const [];
  List<UserProfile> _people = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _query => _controller.text.trim();

  // ── Results ────────────────────────────────────────────────────────────────

  List<_Entry> _buildEntries() {
    final q = _query.toLowerCase();
    final entries = <_Entry>[];

    for (final c in _commands) {
      if (c.location == NileRoutes.createCurrent && !NilePlatform.canCreateCurrents) {
        continue;
      }
      if (q.isNotEmpty &&
          !c.label.toLowerCase().contains(q) &&
          !c.keywords.contains(q)) {
        continue;
      }
      entries.add(
        _Entry(
          icon: c.icon,
          title: c.label,
          subtitle: 'Go to',
          onOpen: () => _go(c.location),
        ),
      );
    }

    for (final e in _events) {
      final live = e.status == 'live';
      entries.add(
        _Entry(
          icon: live ? Icons.sensors : Icons.event_outlined,
          title: e.title,
          subtitle: '@${e.hostUsername}',
          trailing: live ? 'Live' : null,
          accent: live ? NileColors.coral : null,
          onOpen: () {
            final loc = NileRoutes.eventOrWatch(
              isLive: live,
              eventId: e.id,
              liveKitEventId: e.liveKitEventId,
            );
            _go(loc, extra: loc.startsWith('/event/') ? e : null);
          },
        ),
      );
    }

    for (final p in _people) {
      entries.add(
        _Entry(
          icon: Icons.person_outline,
          title: p.displayName.isEmpty ? p.username : p.displayName,
          subtitle: '@${p.username}',
          avatarUrl: p.avatarUrl,
          official: p.isOfficial,
          onOpen: () => _go(NileRoutes.profile(p.id)),
        ),
      );
    }

    return entries;
  }

  void _onChanged(String _) {
    setState(() => _selected = 0);
    _debounce?.cancel();
    final q = _query;
    // One character matches almost everything; wait for a second before
    // spending a round-trip.
    if (q.length < 2) {
      setState(() {
        _events = const [];
        _people = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    final token = ++_token;
    try {
      // Started together, awaited separately — one round-trip of latency, and
      // both results keep their own type.
      final eventsFuture = SearchService.searchEvents(q);
      final peopleFuture = SearchService.searchUsers(q);
      final events = await eventsFuture;
      final people = await peopleFuture;
      if (!mounted || token != _token) return;
      setState(() {
        _events = events.items.take(5).toList();
        _people = people.items.take(5).toList();
        _searching = false;
      });
    } catch (_) {
      if (!mounted || token != _token) return;
      setState(() => _searching = false);
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  /// Closes the palette first: it lives on the root navigator, so pushing while
  /// it's still up would put the destination underneath it.
  void _go(String location, {Object? extra}) {
    Navigator.of(context, rootNavigator: true).pop();
    nileRouter.push(location, extra: extra);
  }

  // ── Keyboard ───────────────────────────────────────────────────────────────

  /// Attached to the field's own focus node so it runs before the text editing
  /// actions claim the arrow keys.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final entries = _buildEntries();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1, entries.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1, entries.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (entries.isNotEmpty) entries[_selected.clamp(0, entries.length - 1)].onOpen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context, rootNavigator: true).pop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    // Dart's % is never negative for a positive divisor, so this wraps both
    // ways without a sign fix-up.
    setState(() => _selected = (_selected + delta) % count);
    // Keep the cursor row on screen without animating past several pages.
    if (_scroll.hasClients) {
      final target = (_selected * _rowHeight)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.animateTo(
        target,
        duration: NileMotion.fast,
        curve: NileMotion.curve,
      );
    }
  }

  static const double _rowHeight = 52;

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries();
    if (_selected >= entries.length) _selected = entries.isEmpty ? 0 : entries.length - 1;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 96, left: 24, right: 24),
        child: Material(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
          clipBehavior: Clip.antiAlias,
          child: Container(
            width: 640,
            constraints: const BoxConstraints(maxHeight: 520),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(NileRadius.lg),
              border: Border.all(color: NileColors.borderStrong),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NileSpacing.s16,
                    NileSpacing.s8,
                    NileSpacing.s16,
                    0,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, color: NileColors.txtTertiary, size: 20),
                      const SizedBox(width: NileSpacing.s12),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          autofocus: true,
                          onChanged: _onChanged,
                          style: NileTextStyles.bodyLg(),
                          decoration: InputDecoration(
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            hintText: 'Search events, people, topics',
                            hintStyle: NileTextStyles.bodyLg()
                                .copyWith(color: NileColors.txtTertiary),
                          ),
                        ),
                      ),
                      if (_searching)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: NileColors.txtTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
                Divider(color: NileColors.border, height: 1),
                Flexible(
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(NileSpacing.s32),
                          child: Text(
                            _searching ? 'Searching…' : 'No matches',
                            style: NileTextStyles.bodySm(),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            vertical: NileSpacing.s8,
                          ),
                          itemCount: entries.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (_, i) => _Row(
                            entry: entries[i],
                            selected: i == _selected,
                            onHover: () => setState(() => _selected = i),
                          ),
                        ),
                ),
                Divider(color: NileColors.border, height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s16,
                    vertical: NileSpacing.s8,
                  ),
                  child: Row(
                    children: [
                      _Hint(keys: '↑↓', label: 'Navigate'),
                      const SizedBox(width: NileSpacing.s16),
                      _Hint(keys: '↵', label: 'Open'),
                      const SizedBox(width: NileSpacing.s16),
                      _Hint(keys: 'esc', label: 'Close'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.selected,
    required this.onHover,
  });

  final _Entry entry;
  final bool selected;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: InkWell(
        onTap: entry.onOpen,
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: NileSpacing.s8,
            vertical: NileSpacing.s2,
          ),
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
          decoration: BoxDecoration(
            color: selected ? NileColors.bgRaised : Colors.transparent,
            borderRadius: BorderRadius.circular(NileRadius.sm),
          ),
          child: Row(
            children: [
              if (entry.avatarUrl != null)
                CircleAvatar(
                  radius: 14,
                  backgroundColor: NileColors.bgRaised,
                  backgroundImage: nileAvatarImage(entry.avatarUrl!, 14),
                )
              else
                Icon(
                  entry.icon,
                  size: 20,
                  color: entry.accent ?? NileColors.txtSecondary,
                ),
              const SizedBox(width: NileSpacing.s12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NileTextStyles.labelMd(),
                          ),
                        ),
                        if (entry.official) ...[
                          const SizedBox(width: NileSpacing.s4),
                          const OfficialBadge(size: 14),
                        ],
                      ],
                    ),
                    if (entry.subtitle != null)
                      Text(
                        entry.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.caption(),
                      ),
                  ],
                ),
              ),
              if (entry.trailing != null)
                Text(
                  entry.trailing!,
                  style: NileTextStyles.caption().copyWith(
                    color: entry.accent ?? NileColors.txtTertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.keys, required this.label});
  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: NileColors.border),
          borderRadius: BorderRadius.circular(NileRadius.xs),
        ),
        child: Text(keys, style: NileTextStyles.caption()),
      ),
      const SizedBox(width: NileSpacing.s6),
      Text(label, style: NileTextStyles.caption()),
    ],
  );
}
