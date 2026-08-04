import 'package:flutter/material.dart';

import '../services/pricing_service.dart';
import '../theme.dart';

/// Inline pricing coach for the create/edit event forms: the minimum this
/// event can be ticketed at, and what the host keeps per ticket at the price
/// they've typed. Deliberately shows only host-facing numbers — the cost
/// drivers behind the floor stay server-side.
class PayoutPreviewCard extends StatelessWidget {
  /// Price currently typed, in cents. Null/0 = free.
  final int? priceCents;

  /// Break-even floor for the current duration + camera count.
  final int minCents;

  final int cameraCount;
  final PricingConfig config;

  const PayoutPreviewCard({
    super.key,
    required this.priceCents,
    required this.minCents,
    required this.cameraCount,
    required this.config,
  });

  static String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final price = priceCents ?? 0;
    final perTicket = config.creatorEarningsCents(price);
    final sample = config.floorAssumedTickets;

    return Container(
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Minimum for this event', _money(minCents), emphasize: price == 0),
          if (price > 0) ...[
            const SizedBox(height: NileSpacing.s6),
            _row('You earn per ticket', '~${_money(perTicket)}', emphasize: true),
            const SizedBox(height: NileSpacing.s8),
            Text(
              '$sample tickets → ${_money(perTicket * sample)}',
              style: NileTextStyles.caption().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
          ] else if (cameraCount > 1) ...[
            const SizedBox(height: NileSpacing.s8),
            Text(
              'Multi-camera streams cost more to run — tickets start at '
              '${_money(minCents)}.',
              style: NileTextStyles.caption().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool emphasize = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ),
        const SizedBox(width: NileSpacing.s8),
        Text(
          value,
          style: NileTextStyles.labelMd().copyWith(
            color: emphasize ? NileColors.volt : NileColors.txtPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
