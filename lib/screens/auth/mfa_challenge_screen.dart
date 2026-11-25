import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../router.dart';
import '../../services/mfa_service.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';

/// Second-step login challenge, shown by the auth gate when a session sits at
/// aal1 but a verified factor requires aal2. On success the session elevates and
/// [onVerified] tells the gate to re-render into the app. A "use a recovery
/// code" link opens the lost-authenticator flow.
class MfaChallengeScreen extends StatefulWidget {
  final VoidCallback onVerified;

  const MfaChallengeScreen({super.key, required this.onVerified});

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  final _codeCtrl = TextEditingController();
  String? _factorId;
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFactor();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFactor() async {
    final factors = await MfaService.verifiedFactors();
    if (mounted && factors.isNotEmpty) {
      setState(() => _factorId = factors.first.id);
    }
  }

  Future<void> _verify() async {
    final id = _factorId;
    if (id == null) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await MfaService.verify(factorId: id, code: _codeCtrl.text.trim());
      widget.onVerified();
    } catch (_) {
      if (mounted) {
        setState(() {
          _verifying = false;
          _error = 'That code didn\'t match. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s32,
              vertical: NileSpacing.s40,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.shield_outlined, color: NileColors.volt, size: 40),
                const SizedBox(height: NileSpacing.s24),
                Text('Two-step verification',
                    style: NileTextStyles.headingLg()),
                const SizedBox(height: NileSpacing.s8),
                Text(
                  'Enter the 6-digit code from your authenticator app.',
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
                const SizedBox(height: NileSpacing.s32),
                TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _verify(),
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: NileTextStyles.headingSm().copyWith(letterSpacing: 8),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '000000',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: NileSpacing.s24),
                FilledButton(
                  onPressed: _verifying ? null : _verify,
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                    disabledBackgroundColor: NileColors.bgRaised,
                  ),
                  child: _verifying
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: NileColors.onVolt,
                          ),
                        )
                      : const Text('Verify'),
                ),
                const SizedBox(height: NileSpacing.s8),
                TextButton(
                  onPressed: () => context.push(NileRoutes.mfaRecovery),
                  child: Text(
                    'Use a recovery code instead',
                    style: NileTextStyles.labelMd().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: NileSpacing.s24),
                TextButton(
                  onPressed: () => supabase.auth.signOut(),
                  child: Text(
                    'Sign out',
                    style: NileTextStyles.labelMd().copyWith(
                      color: NileColors.txtTertiary,
                    ),
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
