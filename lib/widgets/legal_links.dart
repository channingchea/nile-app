import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../theme.dart';

/// Open one of Nile's published legal documents in the system browser. The
/// canonical copies live on the marketing site so a wording change never needs
/// an app release.
Future<void> openLegalUrl(String url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// The agreement line App Store Guideline 1.2 looks for: an explicit statement,
/// at the point of account creation, that the user is accepting the Terms (which
/// are Nile's EULA) and the Privacy Policy — with both reachable in one tap.
///
/// Rendered on both signup paths. A user who taps "Continue with Apple" never
/// sees the email form, so the social buttons carry their own copy.
class LegalConsentText extends StatefulWidget {
  /// Completes the sentence "By {action} you agree to…". 'continuing' on the
  /// social buttons, 'creating an account' on the email form.
  final String action;

  final TextAlign align;

  const LegalConsentText({
    super.key,
    this.action = 'creating an account',
    this.align = TextAlign.center,
  });

  @override
  State<LegalConsentText> createState() => _LegalConsentTextState();
}

class _LegalConsentTextState extends State<LegalConsentText> {
  late final _terms = TapGestureRecognizer()
    ..onTap = () => openLegalUrl(termsUrl);
  late final _privacy = TapGestureRecognizer()
    ..onTap = () => openLegalUrl(privacyUrl);

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = NileTextStyles.bodySm().copyWith(color: NileColors.txtTertiary);
    final link = base.copyWith(
      color: NileColors.txtSecondary,
      decoration: TextDecoration.underline,
      decorationColor: NileColors.txtSecondary,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: 'By ${widget.action} you agree to our '),
          TextSpan(text: 'Terms of Service', style: link, recognizer: _terms),
          const TextSpan(text: ' and '),
          TextSpan(text: 'Privacy Policy', style: link, recognizer: _privacy),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: widget.align,
    );
  }
}
