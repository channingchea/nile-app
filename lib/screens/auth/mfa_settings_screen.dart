import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/mfa_service.dart';
import '../../theme.dart';
import 'mfa_backup_codes_screen.dart';
import 'mfa_enroll_screen.dart';

/// Two-factor authentication hub (Settings → Security). Shows current status and
/// offers enable / regenerate-codes / turn-off. Turning off requires a fresh
/// valid code (re-challenge).
class MfaSettingsScreen extends StatefulWidget {
  const MfaSettingsScreen({super.key});

  @override
  State<MfaSettingsScreen> createState() => _MfaSettingsScreenState();
}

class _MfaSettingsScreenState extends State<MfaSettingsScreen> {
  bool _loading = true;
  bool _hasFactor = false;
  RecoveryCodeStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final has = await MfaService.hasVerifiedFactor();
      final status = has ? await MfaService.recoveryStatus() : null;
      if (!mounted) return;
      setState(() {
        _hasFactor = has;
        _status = status;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enable() async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const MfaEnrollScreen()),
    );
    if (done == true) _load();
  }

  Future<void> _regenerate() async {
    final confirm = await _confirm(
      title: 'Regenerate backup codes?',
      body: 'Your existing backup codes will stop working and a new set will be '
          'shown once.',
      action: 'Regenerate',
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final codes = await MfaService.generateRecoveryCodes();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MfaBackupCodesScreen(codes: codes, afterEnroll: false),
        ),
      );
      await _load();
    } catch (_) {
      _showError('Couldn\'t regenerate codes. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    final factors = await MfaService.verifiedFactors();
    if (factors.isEmpty || !mounted) return;
    final code = await showDialog<String>(
      context: context,
      builder: (_) => _CodeChallengeDialog(factorId: factors.first.id),
    );
    if (code != true.toString()) return; // dialog pops 'true' string on success
    setState(() => _busy = true);
    try {
      await MfaService.unenrollAll();
      await MfaService.clearRecoveryCodes();
      await _load();
    } catch (_) {
      _showError('Couldn\'t turn off two-factor. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text(title, style: NileTextStyles.headingSm()),
        content: Text(body, style: NileTextStyles.bodySm()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor:
                  destructive ? NileColors.error : NileColors.txtPrimary,
            ),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: NileTextStyles.bodyMd()),
        backgroundColor: NileColors.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: NileColors.txtPrimary),
        title: Text('Two-factor auth', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s32,
                    vertical: NileSpacing.s24,
                  ),
                  child: _hasFactor ? _onView() : _offView(),
                ),
        ),
      ),
    );
  }

  Widget _offView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusCard(
          icon: Icons.gpp_maybe_outlined,
          iconColor: NileColors.txtSecondary,
          title: 'Two-factor is off',
          subtitle:
              'Add a second step at sign-in so a password alone isn\'t enough '
              'to access your account.',
        ),
        const SizedBox(height: NileSpacing.s24),
        FilledButton(
          onPressed: _busy ? null : _enable,
          style: _primaryBtn(),
          child: const Text('Turn on two-factor'),
        ),
      ],
    );
  }

  Widget _onView() {
    final s = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusCard(
          icon: Icons.verified_user_outlined,
          iconColor: NileColors.volt,
          title: 'Two-factor is on',
          subtitle: s == null
              ? 'You\'ll enter a code from your authenticator app at sign-in.'
              : '${s.remaining} of ${s.total} backup codes remaining.',
        ),
        const SizedBox(height: NileSpacing.s24),
        OutlinedButton(
          onPressed: _busy ? null : _regenerate,
          style: OutlinedButton.styleFrom(
            foregroundColor: NileColors.txtPrimary,
            side: BorderSide(color: NileColors.bgRaised),
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          ),
          child: const Text('Regenerate backup codes'),
        ),
        const SizedBox(height: NileSpacing.s16),
        TextButton(
          onPressed: _busy ? null : _turnOff,
          style: TextButton.styleFrom(
            foregroundColor: NileColors.error,
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          ),
          child: const Text('Turn off two-factor'),
        ),
      ],
    );
  }

  ButtonStyle _primaryBtn() => FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
        backgroundColor: NileColors.volt,
        foregroundColor: NileColors.onVolt,
        disabledBackgroundColor: NileColors.bgRaised,
      );
}

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  const _StatusCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s24),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 32),
          const SizedBox(height: NileSpacing.s16),
          Text(title, style: NileTextStyles.headingMd()),
          const SizedBox(height: NileSpacing.s8),
          Text(
            subtitle,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Re-challenge dialog used before turning 2FA off. Verifies a current code and
/// pops the string 'true' on success (caller then performs the disable).
class _CodeChallengeDialog extends StatefulWidget {
  final String factorId;
  const _CodeChallengeDialog({required this.factorId});

  @override
  State<_CodeChallengeDialog> createState() => _CodeChallengeDialogState();
}

class _CodeChallengeDialogState extends State<_CodeChallengeDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MfaService.verify(
        factorId: widget.factorId,
        code: _ctrl.text.trim(),
      );
      if (mounted) Navigator.pop(context, true.toString());
    } on AuthException catch (_) {
      if (mounted) setState(() => _error = 'Incorrect code.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Incorrect code.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text('Confirm it\'s you', style: NileTextStyles.headingSm()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter a current code from your authenticator app to turn off '
            'two-factor.',
            style: NileTextStyles.bodySm(),
          ),
          const SizedBox(height: NileSpacing.s16),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            textAlign: TextAlign.center,
            onSubmitted: (_) => _submit(),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: NileTextStyles.headingSm().copyWith(letterSpacing: 6),
            decoration: InputDecoration(
              counterText: '',
              hintText: '000000',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          style: TextButton.styleFrom(foregroundColor: NileColors.error),
          child: const Text('Turn off'),
        ),
      ],
    );
  }
}
