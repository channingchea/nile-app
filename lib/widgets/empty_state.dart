import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared empty/error state: icon, title, one line of body copy, and an
/// optional single action. Keeps every list screen's "nothing here" moment
/// consistent.
class NileEmptyState extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  const NileEmptyState({
    super.key,
    required this.icon,
    this.iconColor = NileColors.border,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: iconColor),
            const SizedBox(height: NileSpacing.s16),
            Text(title, style: NileTextStyles.headingMd()),
            const SizedBox(height: NileSpacing.s8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: NileSpacing.s24),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
