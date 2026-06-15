import 'package:flutter/material.dart';
import '../../theme.dart';

/// Trailing spinner shown at the end of a paginated list while the next page
/// loads. Append this as the final item when `hasMore` is true.
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: NileSpacing.s16),
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: NileColors.volt,
        ),
      ),
    ),
  );
}
