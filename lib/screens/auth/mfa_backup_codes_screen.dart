import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../theme.dart';

/// Show-once screen for backup recovery codes. Displayed right after enrollment
/// and after a regenerate. Codes cannot be retrieved again, so the user must
/// confirm they've saved them before continuing. Pops `true` on confirm.
class MfaBackupCodesScreen extends StatefulWidget {
  final List<String> codes;

  /// When true (right after enrolling), the copy tweaks to "You're all set".
  final bool afterEnroll;

  const MfaBackupCodesScreen({
    super.key,
    required this.codes,
    this.afterEnroll = true,
  });

  @override
  State<MfaBackupCodesScreen> createState() => _MfaBackupCodesScreenState();
}

class _MfaBackupCodesScreenState extends State<MfaBackupCodesScreen> {
  bool _saved = false;

  String get _joined => widget.codes.join('\n');

  void _copy() {
    Clipboard.setData(ClipboardData(text: _joined));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Codes copied', style: NileTextStyles.bodyMd()),
        backgroundColor: NileColors.success,
      ),
    );
  }

  void _share() {
    Share.share(_joined, subject: 'Nile backup recovery codes');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // These codes are shown once — block an accidental swipe-back until saved.
      canPop: _saved,
      child: Scaffold(
        backgroundColor: NileColors.bgPage,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          iconTheme: IconThemeData(color: NileColors.txtPrimary),
          title: Text('Backup codes', style: NileTextStyles.headingSm()),
        ),
        body: NileMaxWidth(
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s32,
                vertical: NileSpacing.s24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.afterEnroll
                        ? 'Two-factor authentication is on'
                        : 'Your new backup codes',
                    style: NileTextStyles.headingMd(),
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  Text(
                    'Save these codes somewhere safe. If you lose your '
                    'authenticator app, each code lets you sign in once and '
                    'reset two-factor. They won\'t be shown again.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                  const SizedBox(height: NileSpacing.s24),
                  _CodesCard(codes: widget.codes),
                  const SizedBox(height: NileSpacing.s16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copy,
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: NileColors.txtPrimary,
                            side: BorderSide(color: NileColors.bgRaised),
                            padding: const EdgeInsets.symmetric(
                              vertical: NileSpacing.s16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: NileSpacing.s16),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _share,
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: const Text('Share'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: NileColors.txtPrimary,
                            side: BorderSide(color: NileColors.bgRaised),
                            padding: const EdgeInsets.symmetric(
                              vertical: NileSpacing.s16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: NileSpacing.s24),
                  CheckboxListTile(
                    value: _saved,
                    onChanged: (v) => setState(() => _saved = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: NileColors.volt,
                    checkColor: NileColors.onVolt,
                    title: Text(
                      'I\'ve saved my backup codes',
                      style: NileTextStyles.bodyMd(),
                    ),
                  ),
                  const SizedBox(height: NileSpacing.s16),
                  FilledButton(
                    onPressed: _saved ? () => context.pop(true) : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: NileSpacing.s16,
                      ),
                      backgroundColor: NileColors.volt,
                      foregroundColor: NileColors.onVolt,
                      disabledBackgroundColor: NileColors.bgRaised,
                    ),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The codes laid out in a monospace two-column grid inside a surface card.
class _CodesCard extends StatelessWidget {
  final List<String> codes;
  const _CodesCard({required this.codes});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 4.2,
        mainAxisSpacing: NileSpacing.s8,
        crossAxisSpacing: NileSpacing.s16,
        children: [
          for (final c in codes)
            Center(
              child: Text(
                c,
                style: NileTextStyles.bodyMd().copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1.5,
                  color: NileColors.txtPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
