import 'package:flutter/material.dart';
import '../screens/payouts_screen.dart';
import '../services/payout_service.dart';
import '../theme.dart';

/// Gate for anything that needs an ACTIVE payout account — publishing a paid
/// event (default copy) or opening an event to sponsorship (0079; pass custom
/// [title]/[message]). Returns true when payouts are active, false when
/// blocked — in which case a sheet offers to set them up. The server backs
/// this up; this is the UX front door.
Future<bool> ensurePaidPublishAllowed(
  BuildContext context, {
  String title = 'Set up payouts to publish',
  String message =
      'Paid events need a connected payout account so your ticket '
      'revenue reaches you. Set it up, then publish.',
}) async {
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
    builder: (_) => _PayoutGateSheet(title: title, message: message),
  );
  return false;
}

class _PayoutGateSheet extends StatelessWidget {
  const _PayoutGateSheet({required this.title, required this.message});
  final String title;
  final String message;

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
            Text(title, style: NileTextStyles.headingSm()),
            const SizedBox(height: 8),
            Text(
              message,
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
