import 'package:flutter/material.dart';

import '../services/live_elements.dart';
import '../theme.dart';

/// The host's look back at a finished show: every element viewers could tap,
/// with each choice's final count and share. Totals only — never who voted
/// what. Draws nothing when no element took taps.
class ElementResults extends StatelessWidget {
  const ElementResults({
    super.key,
    required this.elements,
    required this.tallies,
  });

  final List<LiveElement> elements;
  final Map<String, ElementTally> tallies;

  /// The elements that have results to show.
  static List<LiveElement> tappable(List<LiveElement> elements) => [
    for (final e in elements)
      if (e.choices.isNotEmpty) e,
  ];

  @override
  Widget build(BuildContext context) {
    final items = tappable(elements);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Results', style: NileTextStyles.labelSm()),
        const SizedBox(height: NileSpacing.s6),
        for (final e in items) ...[
          _ElementCard(element: e, tally: tallies[e.id] ?? const {}),
          const SizedBox(height: NileSpacing.s8),
        ],
      ],
    );
  }
}

class _ElementCard extends StatelessWidget {
  const _ElementCard({required this.element, required this.tally});

  final LiveElement element;
  final ElementTally tally;

  @override
  Widget build(BuildContext context) {
    final choices = element.choices;
    final total = choices.fold(0, (sum, c) => sum + (tally[c] ?? 0));
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.md),
        border: Border.all(color: NileColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  element.name,
                  overflow: TextOverflow.ellipsis,
                  style: NileTextStyles.labelMd(),
                ),
              ),
              Text(
                total == 1 ? '1 vote' : '$total votes',
                style: NileTextStyles.caption(),
              ),
            ],
          ),
          for (final c in choices) ...[
            const SizedBox(height: NileSpacing.s8),
            _ChoiceRow(label: c, count: tally[c] ?? 0, total: total),
          ],
        ],
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.count,
    required this.total,
  });

  final String label;
  final int count;
  final int total;

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : count / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.bodySm(),
              ),
            ),
            Text(
              '$count · ${(share * 100).round()}%',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: NileSpacing.s4),
        ClipRRect(
          borderRadius: BorderRadius.circular(NileRadius.pill),
          child: LinearProgressIndicator(
            value: share,
            minHeight: NileSpacing.s6,
            color: NileColors.volt,
            backgroundColor: NileColors.bgRaised,
          ),
        ),
      ],
    );
  }
}
