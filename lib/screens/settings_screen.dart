import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/account_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import 'blocked_accounts_screen.dart';
import 'edit_profile_screen.dart';
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

  void _notifications(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationPreferencesScreen()),
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
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Settings')),
      body: NileMaxWidth(
        child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _SettingsTile(
            icon: Icons.edit_outlined,
            label: 'Edit profile',
            onTap: () => _editProfile(context),
          ),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.confirmation_number_outlined,
            label: 'My tickets',
            onTap: () => _myTickets(context),
          ),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.account_balance_outlined,
            label: 'Payouts',
            onTap: () => _payouts(context),
          ),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            onTap: () => _notifications(context),
          ),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.block,
            label: 'Blocked accounts',
            onTap: () => _blockedAccounts(context),
          ),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.logout,
            label: 'Sign out',
            color: NileColors.error,
            onTap: () => _signOut(context),
          ),
          const SizedBox(height: 10),
          _SettingsTile(
            icon: Icons.delete_forever_outlined,
            label: 'Delete account',
            color: NileColors.error,
            onTap: () => _deleteAccount(context),
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

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;
  const _SettingsTile({
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
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
        ),
        child: Row(
          children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: NileTextStyles.labelLg().copyWith(color: c)),
            ),
            if (color == null)
              const Icon(Icons.chevron_right,
                  color: NileColors.txtTertiary, size: 20),
          ],
        ),
      ),
    );
  }
}
