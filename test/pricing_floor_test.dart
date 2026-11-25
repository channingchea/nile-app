import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/pricing_service.dart';
import 'package:nile_app/widgets/duration_field.dart';
import 'package:nile_app/widgets/payout_preview_card.dart';

/// docs/plans/cost-controls-and-60-payout.md, phases 2-3. The floor table is
/// the same one migration 0155 was checked against on the database.
void main() {
  const c = PricingConfig.fallback;

  test('floor: \$3 for the first hour, +\$1 per extra half hour', () {
    const table = {
      1: 300,
      60: 300,
      61: 400,
      90: 400,
      91: 500,
      120: 500,
      480: 1700,
    };
    for (final e in table.entries) {
      expect(
        c.minTicketCentsFor(durationMinutes: e.key),
        e.value,
        reason: '${e.key} min',
      );
    }
    expect(c.floorRule, '\$3 for the first hour, +\$1 per extra 30 min');
  });

  test('config from app_config; missing columns fall back', () {
    final cfg = PricingConfig.fromJson({
      'floor_base_cents': 500,
      'floor_step_cents': 150,
      'floor_step_minutes': 60,
      'creator_revenue_share': '0.60',
      'free_max_stream_minutes': 90,
    });
    expect(cfg.minTicketCentsFor(durationMinutes: 121), 500 + 150 * 2);
    expect(cfg.creatorEarningsCents(1000), 600);
    expect(cfg.freeMaxStreamMinutes, 90);
    expect(cfg.maxStreamMinutes, 480);
    expect(cfg.floorRule, '\$5 for the first hour, +\$1.50 per extra 60 min');
  });

  test('the free-show error has its own copy', () {
    expect(
      PricingService.friendlyError(
        'PostgrestException: free_duration_exceeds_max',
      ),
      contains('Free shows are capped at 2 hours'),
    );
    expect(
      PricingService.friendlyError('duration_exceeds_max'),
      contains('capped at 8 hours'),
    );
  });

  testWidgets('payout card shows the rule', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PayoutPreviewCard(
            priceCents: 500,
            minCents: 500,
            cameraCount: 1,
            config: c,
          ),
        ),
      ),
    );
    expect(
      find.text('\$3 for the first hour, +\$1 per extra 30 min.'),
      findsOneWidget,
    );
    expect(find.text('~\$2.50'), findsOneWidget);
  });

  testWidgets('a free show is refused past its cap, with the way out', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    final duration = TextEditingController(text: '2.5');
    Widget field({required bool free}) => MaterialApp(
      home: Scaffold(
        body: Form(
          key: form,
          child: DurationField(
            controller: duration,
            inHours: true,
            onUnitChanged: (_) {},
            preview: null,
            maxMinutes: free ? c.freeMaxStreamMinutes : c.maxStreamMinutes,
            freeCap: free,
          ),
        ),
      ),
    );
    await tester.pumpWidget(field(free: true));
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.textContaining('add a ticket price'), findsOneWidget);

    await tester.pumpWidget(field(free: false));
    expect(form.currentState!.validate(), isTrue);
  });
}
