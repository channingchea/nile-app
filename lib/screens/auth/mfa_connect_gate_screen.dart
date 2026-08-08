import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../router.dart';
import '../../theme.dart';

/// Gate shown when a host tries to start Stripe Connect onboarding without 2FA.
/// Explains why it's required and routes into enrollment. Pops `true` once the
/// user has enrolled, so the caller can resume onboarding.
class MfaConnectGateScreen extends StatelessWidget {
  const MfaConnectGateScreen({super.key});

  Future<void> _setUp(BuildContext context) async {
    final done = await context.push<bool>(NileRoutes.mfaEnroll);
    if (done == true && context.mounted) context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: NileColors.txtPrimary),
        title: Text('Secure your account', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s32,
              vertical: NileSpacing.s24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.shield_outlined, color: NileColors.volt, size: 40),
                const SizedBox(height: NileSpacing.s24),
                Text(
                  'Turn on two-factor to get paid',
                  style: NileTextStyles.headingMd(),
                ),
                const SizedBox(height: NileSpacing.s8),
                Text(
                  'Because payouts involve real money, we require two-factor '
                  'authentication before you set up a Stripe account. It only '
                  'takes a minute.',
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => _setUp(context),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                  ),
                  child: const Text('Set up two-factor'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
