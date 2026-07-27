import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/account_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/nile_glass_app_bar.dart';
import '../widgets/pressable.dart';
import 'appearance_screen.dart';
import 'auth/feature_intro_screen.dart';
import 'auth/interest_picker_screen.dart';
import 'auth/mfa_settings_screen.dart';
import 'blocked_accounts_screen.dart';
import 'change_password_screen.dart';
import 'edit_profile_screen.dart';
import 'my_currents_screen.dart';
import 'my_tickets_screen.dart';
import 'notification_preferences_screen.dart';
import 'payouts_screen.dart';

/// Own-profile settings hub: edit profile, my tickets, payouts, sign out.
class SettingsScreen extends StatelessWidget {
  final UserProfile profile;

  const SettingsScreen({super.key, required this.profile});

  Future<void> _editProfile(BuildContext context) async {
    final updated = await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: profile)),
    );
    // Bubble the updated profile back to ProfileScreen.
    if (updated != null && context.mounted) Navigator.pop(context, updated);
  }

  void _appearance(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppearanceScreen()),
    );
  }

  void _myCurrents(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyCurrentsScreen()),
    );
  }

  void _myTickets(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyTicketsScreen()),
    );
  }

  void _payouts(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PayoutsScreen()),
    );
  }

  void _interests(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InterestPickerScreen()),
    );
  }

  void _notifications(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationPreferencesScreen()),
    );
  }

  void _changePassword(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
    );
  }

  void _twoFactor(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MfaSettingsScreen()),
    );
  }

  void _blockedAccounts(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BlockedAccountsScreen()),
    );
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
      // Sign-out triggers _AuthGate to route back to login; just pop dialogs.
      if (context.mounted) Navigator.popUntil(context, (r) => r.isFirst);
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
  final List<_SettingsRow> rows;
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
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
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
            if (color == null)
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
