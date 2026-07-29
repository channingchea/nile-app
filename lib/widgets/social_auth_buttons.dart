import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/social_auth_service.dart';
import '../theme.dart';

/// "or continue with" divider + Apple / Google buttons, shared by the login
/// and signup screens. Apple is iOS-only and listed first there (HIG: at least
/// as prominent as other providers). Navigation after success is automatic —
/// _AuthGate reacts to the auth state stream.
class SocialAuthButtons extends StatefulWidget {
  const SocialAuthButtons({super.key});

  @override
  State<SocialAuthButtons> createState() => _SocialAuthButtonsState();
}

class _SocialAuthButtonsState extends State<SocialAuthButtons> {
  bool _busy = false;

  static bool get _appleSupported => !kIsWeb && Platform.isIOS;

  Future<void> _run(Future<bool> Function() flow) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await flow(); // false = user cancelled → silent no-op
    } on SocialAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message, style: NileTextStyles.bodyMd()),
            backgroundColor: NileColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button({
    required Widget icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton(
      onPressed: _busy ? null : onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: NileSpacing.s12),
          Text(label),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── "or continue with" divider ─────────────────────────────────────
        Row(
          children: [
            Expanded(child: Divider(color: NileColors.border)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
              child: Text(
                'or continue with',
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ),
            Expanded(child: Divider(color: NileColors.border)),
          ],
        ),
        const SizedBox(height: NileSpacing.s24),

        // Apple first on iOS (HIG prominence requirement).
        if (_appleSupported) ...[
          _button(
            icon: Icon(Icons.apple, size: 24, color: NileColors.txtPrimary),
            label: 'Continue with Apple',
            onPressed: () => _run(SocialAuthService.signInWithApple),
          ),
          const SizedBox(height: NileSpacing.s12),
        ],
        _button(
          icon: SvgPicture.string(_googleLogoSvg, width: 20, height: 20),
          label: 'Continue with Google',
          onPressed: () => _run(SocialAuthService.signInWithGoogle),
        ),
      ],
    );
  }
}

/// Official multi-color Google "G" mark.
const String _googleLogoSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
<path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
<path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
<path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
<path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
</svg>
''';
