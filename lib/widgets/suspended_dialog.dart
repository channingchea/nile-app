import 'package:flutter/material.dart';

import '../config.dart';
import '../theme.dart';
import 'legal_links.dart';

/// A suspended account can't sign in, and GoTrue says so with a bare
/// "User is banned" — which read like a bug, told the person nothing, and left
/// them nowhere to go (P3 #35).
///
/// The reason itself can't be shown here: reading `moderation_notices` needs a
/// session, and a banned account can't hold one. So this says what happened,
/// and hands off to the appeal form, which is where a human quotes the reason
/// back.
bool isSuspendedAuthError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('banned') || text.contains('user_banned');
}

Future<void> showSuspendedDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text('Your account is suspended', style: NileTextStyles.headingSm()),
      content: Text(
        "You can't sign in to Nile right now because your account was suspended "
        'for breaking our Community Guidelines.\n\n'
        'If you think that was a mistake, appeal it and someone who '
        "wasn't part of the original decision will look again.",
        style: NileTextStyles.bodySm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            openLegalUrl(appealUrl);
          },
          child: const Text('Appeal this decision'),
        ),
      ],
    ),
  );
}
