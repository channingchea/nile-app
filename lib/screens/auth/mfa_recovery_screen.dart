import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/mfa_service.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';
import 'mfa_enroll_screen.dart';

/// Lost-authenticator recovery. Reached from the login challenge via "Use a
/// recovery code instead." The user enters one backup code; the server verifies
/// it, marks it used, and unenrolls their factors. We refresh the session so the
/// local assurance level drops (no factor left), then offer to re-enroll or
/// continue with 2FA off. Either way the auth gate rebuilds underneath into the
/// app once the session refresh lands.
class MfaRecoveryScreen extends StatefulWidget {
  const MfaRecoveryScreen({super.key});

  @override
  State<MfaRecoveryScreen> createState() => _MfaRecoveryScreenState();
}

class _MfaRecoveryScreenState extends State<MfaRecoveryScreen> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MfaService.consumeRecoveryCode(code);
      // Refresh so the local session reflects the now-removed factor; this drops
      // the assurance requirement and lets the gate through underneath us.
      await supabase.auth.refreshSession();
      if (mounted) setState(() => _done = true);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'That code isn\'t valid or was already used.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reEnroll() async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const MfaEnrollScreen()),
    );
    // Re-enrolled: close recovery too so we land in the app (gate root).
    if (done == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: NileColors.txtPrimary),
        title: Text('Recovery code', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s32,
              vertical: NileSpacing.s24,
            ),
            child: _done ? _resetState() : _entryState(),
          ),
        ),
      ),
    );
  }

  Widget _entryState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Enter a backup code', style: NileTextStyles.headingMd()),
        const SizedBox(height: NileSpacing.s8),
        Text(
          'Use one of the recovery codes you saved when you turned on '
          'two-factor. Each code works once.',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: NileSpacing.s24),
        TextField(
          controller: _codeCtrl,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          textAlign: TextAlign.center,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
          ],
          style: NileTextStyles.headingSm().copyWith(letterSpacing: 2),
          decoration: InputDecoration(
            hintText: 'XXXX-XXXX-XXXX',
            errorText: _error,
          ),
        ),
        const SizedBox(height: NileSpacing.s24),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: _primaryBtn(),
          child: _busy
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.onVolt,
                  ),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }

  Widget _resetState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.lock_open_outlined, color: NileColors.volt, size: 40),
        const SizedBox(height: NileSpacing.s16),
        Text('You\'re back in', style: NileTextStyles.headingMd()),
        const SizedBox(height: NileSpacing.s8),
        Text(
          'Two-factor is now off. Set it up again with a new authenticator to '
          'keep your account protected.',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: NileSpacing.s24),
        FilledButton(
          onPressed: _reEnroll,
          style: _primaryBtn(),
          child: const Text('Set up two-factor again'),
        ),
        const SizedBox(height: NileSpacing.s8),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Skip for now',
            style: NileTextStyles.labelMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
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
