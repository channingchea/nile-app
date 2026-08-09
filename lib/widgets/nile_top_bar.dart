import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../router.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import 'nile_command_palette.dart';

/// The desktop top bar, sitting above the content column (never above the nav
/// rail). Search on the left, page-specific actions in the middle, account on
/// the right.
///
/// It carries the search affordance because the ⌘K palette needs somewhere
/// discoverable to advertise itself — the shortcut is the fast path, the pill
/// is how people learn the shortcut exists.
class NileTopBar extends StatelessWidget {
  const NileTopBar({super.key, this.actions = const []});

  /// Page-specific controls (filter chips, date scrubbers) rendered to the
  /// right of the search field. Phase 7 fills these in per screen.
  final List<Widget> actions;

  static const double height = 54;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgPage,
        border: Border(bottom: BorderSide(color: NileColors.border)),
      ),
      child: Row(
        children: [
          const _SearchPill(),
          const SizedBox(width: NileSpacing.s16),
          ...actions,
          const Spacer(),
          const _AccountButton(),
        ],
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill();

  /// The palette is bound to ⌘K on macOS and Ctrl+K everywhere else, so the
  /// hint has to say the same thing the shortcut handler listens for.
  /// Read from `defaultTargetPlatform`, not `dart:io`, to keep this file
  /// web-safe for the deferred Flutter Web build.
  static String get shortcutLabel =>
      defaultTargetPlatform == TargetPlatform.macOS ? '⌘K' : 'Ctrl K';

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: InkWell(
        onTap: () => NileCommandPalette.show(context),
        borderRadius: BorderRadius.circular(NileRadius.pill),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
          decoration: BoxDecoration(
            color: NileColors.bgSurface,
            borderRadius: BorderRadius.circular(NileRadius.pill),
            border: Border.all(color: NileColors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 16, color: NileColors.txtTertiary),
              const SizedBox(width: NileSpacing.s8),
              Flexible(
                child: Text(
                  'Search events, people, topics',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NileTextStyles.bodySm()
                      .copyWith(color: NileColors.txtTertiary),
                ),
              ),
              const SizedBox(width: NileSpacing.s12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: NileColors.border),
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: Text(shortcutLabel, style: NileTextStyles.caption()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Current user's avatar, straight through to their profile.
///
/// Cached in a static so switching tabs doesn't re-fetch the profile on every
/// shell rebuild; cleared when the signed-in user changes.
class _AccountButton extends StatefulWidget {
  const _AccountButton();

  @override
  State<_AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<_AccountButton> {
  static UserProfile? _cached;
  static String? _cachedFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    if (_cachedFor == uid && _cached != null) return;
    try {
      final profile = await ProfileService.fetchCurrentProfile();
      if (profile == null) return;
      _cached = profile;
      _cachedFor = uid;
      if (mounted) setState(() {});
    } catch (_) {
      // Falls back to the generic glyph.
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _cached?.avatarUrl;
    return Tooltip(
      message: 'Your profile',
      child: InkWell(
        onTap: () => nileRouter.go('/profile'),
        borderRadius: BorderRadius.circular(NileRadius.pill),
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s4),
          child: CircleAvatar(
            radius: 14,
            backgroundColor: NileColors.bgRaised,
            backgroundImage: url == null ? null : nileAvatarImage(url, 14),
            child: url == null
                ? Icon(
                    Icons.person_outline,
                    size: 16,
                    color: NileColors.txtSecondary,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
