import 'package:flutter/material.dart';
import '../screens/payouts_screen.dart';
import '../services/payout_service.dart';
import '../theme.dart';

/// Gate for publishing a PAID event. Returns true when payouts are active (safe
/// to publish), false when blocked — in which case a sheet offers to set them
/// up. Free events must not call this. The server (trigger + checkout fallback)
/// backs this up; this is the UX front door.
Future<bool> ensurePaidPublishAllowed(BuildContext context) async {
  PayoutStatus? status;
  try {
    status = await PayoutService.status();
  } catch (_) {/* treat as not-active; offer setup */}
  if (status?.isActive ?? false) return true;
  if (!context.mounted) return false;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: NileColors.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
    ),
    builder: (_) => const _PayoutGateSheet(),
  );
  return false;
}

class _PayoutGateSheet extends StatelessWidget {
  const _PayoutGateSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24, NileSpacing.s24, NileSpacing.s24, NileSpacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.account_balance_outlined,
                color: NileColors.volt, size: 28),
            const SizedBox(height: 12),
            Text('Set up payouts to publish',
                style: NileTextStyles.headingSm()),
            const SizedBox(height: 8),
            Text(
              'Paid events need a connected payout account so your ticket '
              'revenue reaches you. Set it up, then publish.',
              style: NileTextStyles.bodySm()
                  .copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PayoutsScreen()),
                  );
                },
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('Set up payouts'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Not now',
                  style: NileTextStyles.bodyMd()
                      .copyWith(color: NileColors.txtSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
