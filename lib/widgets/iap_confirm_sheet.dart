import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/iap_service.dart';
import '../theme.dart';

/// Shown after the buyer confirms Apple's sheet, while Nile records the
/// ticket. Closes itself once confirmed; if confirming is slow it says the
/// purchase is safe and keeps retrying in the background
/// (docs/plans/apple-iap-tickets.md, Phase 3 — "still confirming" wireframe).
class IapConfirmSheet extends StatelessWidget {
  const IapConfirmSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: NileColors.bgSurface,
    builder: (_) => const IapConfirmSheet(),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: ValueListenableBuilder<IapStage>(
          valueListenable: IapService.stage,
          builder: (context, stage, _) {
            final slow = stage == IapStage.slow;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (slow)
                  Icon(
                    Icons.verified_user_outlined,
                    color: NileColors.volt,
                    size: 40,
                  )
                else
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                const SizedBox(height: NileSpacing.s16),
                Text(
                  slow ? 'Your purchase is safe' : 'Confirming your ticket…',
                  style: NileTextStyles.headingSm(),
                  textAlign: TextAlign.center,
                ),
                if (slow) ...[
                  const SizedBox(height: NileSpacing.s8),
                  Text(
                    'We’re finishing up. Your ticket will appear on its own — '
                    'you don’t need to buy again.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: NileSpacing.s16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ),
                  TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse(
                        'mailto:support@joinnile.com?subject=Ticket%20purchase',
                      ),
                    ),
                    child: const Text('Contact support'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
