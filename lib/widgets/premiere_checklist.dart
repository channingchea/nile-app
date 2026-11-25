import 'package:flutter/material.dart';

import '../services/premiere.dart';
import '../theme.dart';

/// The host's "Ready" checklist for a Premiere: what's done, what's still
/// needed before the show (required items) and the optional extras.
class PremiereChecklist extends StatelessWidget {
  const PremiereChecklist({super.key, required this.film, this.onOpen});

  final EventFilm film;

  /// Shows a button to the film settings (the event page passes this).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final ready = film.isReady;
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.md),
        border: Border.all(
          color: ready ? NileColors.success : NileColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                ready ? Icons.check_circle : Icons.movie_outlined,
                size: 18,
                color: ready ? NileColors.success : NileColors.txtPrimary,
              ),
              const SizedBox(width: NileSpacing.s8),
              Expanded(
                child: Text(
                  ready ? 'Your premiere is ready' : 'Get your premiere ready',
                  style: NileTextStyles.labelMd(),
                ),
              ),
            ],
          ),
          const SizedBox(height: NileSpacing.s12),
          for (final item in film.checklist)
            Padding(
              padding: const EdgeInsets.only(bottom: NileSpacing.s6),
              child: Row(
                children: [
                  Icon(
                    item.done
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: item.done
                        ? NileColors.success
                        : NileColors.txtTertiary,
                  ),
                  const SizedBox(width: NileSpacing.s8),
                  Expanded(
                    child: Text(
                      item.label,
                      style: NileTextStyles.bodySm().copyWith(
                        color: item.done
                            ? NileColors.txtSecondary
                            : NileColors.txtPrimary,
                      ),
                    ),
                  ),
                  if (!item.required)
                    Text(
                      'Optional',
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                ],
              ),
            ),
          if (onOpen != null) ...[
            const SizedBox(height: NileSpacing.s8),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.movie_edit, size: 18),
              label: Text(ready ? 'Film settings' : 'Upload and set up film'),
            ),
          ],
        ],
      ),
    );
  }
}
