import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
import '../services/account_service.dart';
import '../services/mac_host.dart';
import '../services/profile_service.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/legal_links.dart';
import '../widgets/nile_glass_app_bar.dart';
import '../widgets/pressable.dart';
import 'auth/feature_intro_screen.dart';

/// Own-profile settings hub: edit profile, my tickets, payouts, sign out.
class SettingsScreen extends StatelessWidget {
  final UserProfile profile;

  const SettingsScreen({super.key, required this.profile});

  Future<void> _editProfile(BuildContext context) async {
    final updated = await context.push<UserProfile>(
      NileRoutes.settingsEditProfile,
      extra: profile,
    );
    // Bubble the updated profile back to ProfileScreen.
    if (updated != null && context.mounted) context.pop(updated);
  }

  void _appearance(BuildContext context) {
    context.push(NileRoutes.settingsAppearance);
  }

  void _myCurrents(BuildContext context) {
    context.push(NileRoutes.settingsCurrents);
  }

  void _reportIssue(BuildContext context) {
    context.push(NileRoutes.settingsReport);
  }

  void _myTickets(BuildContext context) {
    context.push(NileRoutes.settingsTickets);
  }

  void _payouts(BuildContext context) {
    context.push(NileRoutes.settingsPayouts);
  }

  void _interests(BuildContext context) {
    context.push(NileRoutes.settingsInterests);
  }

  void _notifications(BuildContext context) {
    context.push(NileRoutes.settingsNotifications);
  }

  void _changePassword(BuildContext context) {
    context.push(NileRoutes.settingsPassword);
  }

  void _twoFactor(BuildContext context) {
    context.push(NileRoutes.settingsMfa);
  }

  void _blockedAccounts(BuildContext context) {
    context.push(NileRoutes.settingsBlocked);
  }

  Future<void> _signOut(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Sign out?', style: NileTextStyles.headingSm()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: NileColors.error),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm == true) await Supabase.instance.client.auth.signOut();
  }

  /// Debug-only. Clears the feature-intro seen flag and signs out so the next
  /// screen is the tour itself, no reinstall needed. Only ever rendered when
  /// kDebugMode is true, so this never reaches a release build.
  Future<void> _replayFeatureIntro(BuildContext context) async {
    await FeatureIntroScreen.resetForTesting();
    if (context.mounted) await Supabase.instance.client.auth.signOut();
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (confirm != true || !context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await AccountService.deleteAccount();
      // Deleting signs out, and the gate redirect reacts to that on its own.
      // Going to the root just unwinds this stack (and the spinner) so the
      // redirect lands them on login from a clean slate.
      if (context.mounted) context.go(NileRoutes.feed);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // dismiss the spinner
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: NileColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      extendBodyBehindAppBar: true,
      appBar: NileGlassBar.appBar(title: const Text('Settings')),
      body: NileMaxWidth(
        child: ListView(
          padding: EdgeInsets.fromLTRB(NileSpacing.s16, topInset + NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
          children: [
            _SettingsSection(
              header: 'EXPERIENCE',
              rows: [
                _SettingsRow(
                  icon: Icons.palette_outlined,
                  label: 'Appearance',
                  onTap: () => _appearance(context),
                ),
                _SettingsRow(
                  icon: Icons.edit_outlined,
                  label: 'Edit profile',
                  onTap: () => _editProfile(context),
                ),
                _SettingsRow(
                  icon: Icons.bubble_chart_outlined,
                  label: 'Your interests',
                  onTap: () => _interests(context),
                ),
                _SettingsRow(
                  icon: Icons.bolt_outlined,
                  label: 'My Currents',
                  onTap: () => _myCurrents(context),
                ),
                _SettingsRow(
                  icon: Icons.notifications_outlined,
                  label: 'Notifications',
                  onTap: () => _notifications(context),
                ),
              ],
            ),
            _SettingsSection(
              header: 'EVENTS',
              rows: [
                _SettingsRow(
                  icon: Icons.confirmation_number_outlined,
                  label: 'My tickets',
                  onTap: () => _myTickets(context),
                ),
                _SettingsRow(
                  icon: Icons.account_balance_outlined,
                  label: 'Payouts',
                  onTap: () => _payouts(context),
                ),
              ],
            ),
            _SettingsSection(
              header: 'SECURITY',
              rows: [
                _SettingsRow(
                  icon: Icons.lock_outline,
                  label: 'Change password',
                  onTap: () => _changePassword(context),
                ),
                _SettingsRow(
                  icon: Icons.shield_outlined,
                  label: 'Two-factor authentication',
                  onTap: () => _twoFactor(context),
                ),
                _SettingsRow(
                  icon: Icons.block,
                  label: 'Blocked accounts',
                  onTap: () => _blockedAccounts(context),
                ),
              ],
            ),
            const _DesktopSection(),
            _SettingsSection(
              header: 'SUPPORT',
              rows: [
                _SettingsRow(
                  icon: Icons.bug_report_outlined,
                  label: 'Report a bug or idea',
                  onTap: () => _reportIssue(context),
                ),
                _SettingsRow(
                  icon: Icons.mail_outline,
                  label: 'Contact us',
                  onTap: () => openLegalUrl(contactUrl),
                ),
              ],
            ),
            // App Store Guideline 1.2: the EULA (our Terms) and the content
            // policy have to be reachable from inside the app, not only from
            // the marketing site. Reviewers look for exactly this list.
            _SettingsSection(
              header: 'LEGAL',
              rows: [
                _SettingsRow(
                  icon: Icons.description_outlined,
                  label: 'Terms of Service',
                  onTap: () => openLegalUrl(termsUrl),
                ),
                _SettingsRow(
                  icon: Icons.privacy_tip_outlined,
                  label: 'Privacy Policy',
                  onTap: () => openLegalUrl(privacyUrl),
                ),
                _SettingsRow(
                  icon: Icons.rule_outlined,
                  label: 'Community Guidelines',
                  onTap: () => openLegalUrl(guidelinesUrl),
                ),
                _SettingsRow(
                  icon: Icons.cookie_outlined,
                  label: 'Cookie Policy',
                  onTap: () => openLegalUrl(cookiesUrl),
                ),
              ],
            ),
            if (kDebugMode)
              _SettingsSection(
                header: 'DEVELOPER',
                rows: [
                  _SettingsRow(
                    icon: Icons.replay,
                    label: 'Replay feature intro',
                    onTap: () => _replayFeatureIntro(context),
                  ),
                ],
              ),
            _SettingsSection(
              rows: [
                _SettingsRow(
                  icon: Icons.logout,
                  label: 'Sign out',
                  color: NileColors.error,
                  onTap: () => _signOut(context),
                ),
              ],
            ),
            _SettingsSection(
              header: 'DANGER ZONE',
              rows: [
                _SettingsRow(
                  icon: Icons.delete_forever_outlined,
                  label: 'Delete account',
                  color: NileColors.error,
                  onTap: () => _deleteAccount(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Mac-only preferences. Absent entirely everywhere else — and also on macOS 12,
/// where `SMAppService` does not exist and the OS cannot answer whether Nile is
/// a login item. A switch that cannot move is worse than no switch.
class _DesktopSection extends StatefulWidget {
  const _DesktopSection();

  @override
  State<_DesktopSection> createState() => _DesktopSectionState();
}

class _DesktopSectionState extends State<_DesktopSection> {
  bool? _launchAtLogin;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (MacHost.supported) _load();
  }

  Future<void> _load() async {
    final state = await MacHost.launchAtLoginEnabled();
    if (mounted) setState(() => _launchAtLogin = state);
  }

  Future<void> _set(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    // The reply is the state actually in force, not what was asked for: the
    // user can have revoked the login item in System Settings, and registering
    // can fail outright on an unsigned build.
    final applied = await MacHost.setLaunchAtLogin(value);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _launchAtLogin = applied ?? _launchAtLogin;
    });
    if (applied == value) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          "macOS wouldn't change that. Check Login Items in System Settings.",
        ),
        backgroundColor: NileColors.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final on = _launchAtLogin;
    if (on == null) return const SizedBox.shrink();
    return _SettingsSection(
      header: 'DESKTOP',
      rows: [
        _SettingsRow(
          icon: Icons.rocket_launch_outlined,
          label: 'Open Nile at login',
          onTap: () => _set(!on),
          trailing: Switch(
            value: on,
            onChanged: _busy ? null : _set,
          ),
        ),
      ],
    );
  }
}

/// Two-step confirmation: the user must type DELETE to enable the button.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();
  bool get _confirmed => _controller.text.trim().toUpperCase() == 'DELETE';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text('Delete account?', style: NileTextStyles.headingSm()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This permanently deletes your profile, posts, events, messages, '
            'and tickets. This cannot be undone.',
            style: NileTextStyles.bodySm(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            style: NileTextStyles.bodyMd(),
            decoration: const InputDecoration(
              hintText: 'Type DELETE to confirm',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _confirmed ? () => Navigator.pop(context, true) : null,
          style: TextButton.styleFrom(foregroundColor: NileColors.error),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

/// A labeled group of settings rows rendered as one rounded surface card,
/// rows stacked inside with no dividers. Header is optional (Sign out has none).
class _SettingsSection extends StatelessWidget {
  final String? header;

  /// Widgets rather than `_SettingsRow` so a row can carry its own state — the
  /// launch-at-login switch has to remember whether it is on.
  final List<Widget> rows;
  const _SettingsSection({required this.rows, this.header});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NileSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.only(
                left: NileSpacing.s4,
                bottom: NileSpacing.s8,
              ),
              child: Text(header!, style: NileTextStyles.labelSm()),
            ),
          NilePressable(
            child: Material(
              color: NileColors.bgSurface,
              borderRadius: BorderRadius.circular(NileRadius.lg),
              clipBehavior: Clip.antiAlias,
              child: Column(children: rows),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single settings row (icon + label + optional chevron) inside a section
/// card. No card/gap of its own; its InkWell ripple is clipped by the card.
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  /// Replaces the chevron. A row with a control on it is a setting you change
  /// here, not a door to somewhere else, so the two are mutually exclusive.
  final Widget? trailing;
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? NileColors.txtPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s16,
          vertical: NileSpacing.s16,
        ),
        child: Row(
          children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: NileTextStyles.labelLg().copyWith(color: c),
              ),
            ),
            if (trailing != null)
              trailing!
            else if (color == null)
              Icon(
                Icons.chevron_right,
                color: NileColors.txtTertiary,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
