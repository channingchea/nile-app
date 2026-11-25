import 'package:flutter/material.dart';

import '../services/live_elements.dart';
import '../theme.dart';

/// The host's look back at a finished show: every element viewers could tap,
/// with each choice's final count and share (answer text, not ids), how many
/// people voted, and a rating's average. A reset poll shows its last round.
/// Totals only — never who voted what. Draws nothing when no element took
/// taps.
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
          _ElementCard(element: e, tally: tallies[e.id] ?? ElementTally.empty),
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
    final poll = element.kind == ElementKinds.poll.wire
        ? PollResults(PollConfig.fromJson(element.config), tally)
        : null;
    final votes = choices.fold(0, (sum, c) => sum + (tally[c] ?? 0));
    final people = poll?.voters ?? votes;
    final average = poll?.average;
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
                [
                  if (average != null) '★ ${average.toStringAsFixed(1)}',
                  people == 1 ? '1 vote' : '$people votes',
                ].join(' · '),
                style: NileTextStyles.caption(),
              ),
            ],
          ),
          for (final c in choices) ...[
            const SizedBox(height: NileSpacing.s8),
            _ChoiceRow(
              label: element.labelOf(c),
              count: tally[c] ?? 0,
              share:
                  poll?.share(c) ?? (votes == 0 ? 0 : (tally[c] ?? 0) / votes),
            ),
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
    required this.share,
  });

  final String label;
  final int count;
  final double share;

  @override
  Widget build(BuildContext context) {
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
