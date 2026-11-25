import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../router.dart';
import '../../services/mfa_service.dart';
import '../../theme.dart';

/// TOTP enrollment: scan the QR (or copy the key) into an authenticator app,
/// then verify a code. On success, generates backup codes and shows them once.
///
/// Pops `true` when enrollment completes (so the caller can refresh). If the
/// user leaves before verifying, the unverified factor is discarded so it can't
/// linger or block login.
class MfaEnrollScreen extends StatefulWidget {
  const MfaEnrollScreen({super.key});

  @override
  State<MfaEnrollScreen> createState() => _MfaEnrollScreenState();
}

class _MfaEnrollScreenState extends State<MfaEnrollScreen> {
  final _codeCtrl = TextEditingController();

  MfaEnrollment? _enrollment;
  String? _enrollError;
  bool _verifying = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _startEnroll();
  }

  @override
  void dispose() {
    // Abandoned before verifying: discard the unverified factor (fire-and-forget).
    if (!_completed && _enrollment != null) {
      MfaService.unenroll(_enrollment!.factorId);
    }
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _startEnroll() async {
    try {
      final e = await MfaService.enroll();
      if (mounted) setState(() => _enrollment = e);
    } catch (e) {
      debugPrint('MFA enroll failed: $e');
      if (mounted) {
        setState(() => _enrollError = 'Couldn\'t start setup. Please try again.');
      }
    }
  }

  Future<void> _verify() async {
    final e = _enrollment;
    if (e == null) return;
    setState(() => _verifying = true);
    try {
      await MfaService.verify(factorId: e.factorId, code: _codeCtrl.text.trim());
      final codes = await MfaService.generateRecoveryCodes();
      _completed = true; // keep dispose from unenrolling the now-verified factor
      if (!mounted) return;
      // Replaces this screen so Back from the codes doesn't re-enter enrollment.
      context.pushReplacement(
        NileRoutes.mfaBackupCodes,
        extra: BackupCodesArgs(codes: codes),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _verifying = false);
        _showError('That code didn\'t match. Check your app and try again.');
      }
    }
  }

  void _copyKey() {
    Clipboard.setData(ClipboardData(text: _enrollment!.secret));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Key copied', style: NileTextStyles.bodyMd()),
        backgroundColor: NileColors.success,
      ),
    );
  }

  void _showError(String message) {
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
        title: Text('Set up two-factor', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: _enrollError != null
              ? _ErrorState(message: _enrollError!, onRetry: () {
                  setState(() => _enrollError = null);
                  _startEnroll();
                })
              : _enrollment == null
                  ? const Center(child: CircularProgressIndicator())
                  : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final e = _enrollment!;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s32,
        vertical: NileSpacing.s24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Scan this with your authenticator app',
            style: NileTextStyles.headingMd(),
          ),
          const SizedBox(height: NileSpacing.s8),
          Text(
            'Use Google Authenticator, Authy, 1Password, or similar, then enter '
            'the 6-digit code it shows.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: NileSpacing.s24),
          Center(
            child: Container(
              padding: const EdgeInsets.all(NileSpacing.s16),
              decoration: BoxDecoration(
                color: Colors.white, // QR must sit on white to scan reliably
                borderRadius: BorderRadius.circular(NileRadius.md),
              ),
              child: SvgPicture.string(e.qrCodeSvg, width: 200, height: 200),
            ),
          ),
          const SizedBox(height: NileSpacing.s24),
          Text('Can\'t scan? Enter this key', style: NileTextStyles.labelSm()),
          const SizedBox(height: NileSpacing.s8),
          InkWell(
            onTap: _copyKey,
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s16,
                vertical: NileSpacing.s16,
              ),
              decoration: BoxDecoration(
                color: NileColors.bgSurface,
                borderRadius: BorderRadius.circular(NileRadius.md),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.secret,
                      style: NileTextStyles.bodyMd().copyWith(
                        fontFamily: 'monospace',
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  Icon(Icons.copy, size: 18, color: NileColors.txtSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(height: NileSpacing.s24),
          TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _verify(),
            style: NileTextStyles.headingSm().copyWith(letterSpacing: 8),
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              counterText: '',
              hintText: '000000',
            ),
          ),
          const SizedBox(height: NileSpacing.s24),
          FilledButton(
            onPressed: _verifying ? null : _verify,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
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
                : const Text('Verify & turn on'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd(),
            ),
            const SizedBox(height: NileSpacing.s16),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
