import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config.dart';
import '../../services/compliance_service.dart';
import '../../theme.dart';
import '../../widgets/legal_links.dart';

/// Birthdate + Terms acceptance, for every account that has neither on file:
/// Google/Apple sign-ups (whose provider hands us no birthdate), and everyone
/// who joined before the age gate existed. Email sign-ups answer both on the
/// signup form and never see this.
///
/// Blocking, like [ClaimUsernameScreen] — the only ways out are answering or
/// signing out.
class ComplianceGateScreen extends StatefulWidget {
  const ComplianceGateScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<ComplianceGateScreen> createState() => _ComplianceGateScreenState();
}

class _ComplianceGateScreenState extends State<ComplianceGateScreen> {
  DateTime? _birthdate;
  bool _saving = false;
  bool _tooYoung = false;

  Future<void> _pickBirthdate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      // Somewhere plausible rather than today, so the picker doesn't open on a
      // date that is guaranteed to be wrong.
      initialDate: _birthdate ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
      helpText: 'Your date of birth',
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked == null) return;
    setState(() {
      _birthdate = picked;
      _tooYoung = !ComplianceService.isOldEnough(picked);
    });
  }

  Future<void> _submit() async {
    final birthdate = _birthdate;
    if (birthdate == null || _saving) return;
    if (!ComplianceService.isOldEnough(birthdate)) {
      setState(() => _tooYoung = true);
      return;
    }

    setState(() => _saving = true);
    try {
      await ComplianceService.recordConsent(birthdate);
      widget.onDone();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "We couldn't save that. Please check your connection and try again.",
              style: NileTextStyles.bodyMd(),
            ),
            backgroundColor: NileColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatted(DateTime d) => '${d.month}/${d.day}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final birthdate = _birthdate;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: NileColors.bgPage,
        body: NileMaxWidth(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s32,
                  vertical: NileSpacing.s24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('One quick thing', style: NileTextStyles.displayMd()),
                    const SizedBox(height: 8),
                    Text(
                      'Nile is for people $minimumAge and over. Confirm your date of '
                      'birth and agree to our terms to keep going. '
                      'Your birthday is private — nobody else sees it.',
                      style: NileTextStyles.bodyMd().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                    const SizedBox(height: 32),

                    // ── Birthdate ────────────────────────────────────────────
                    InkWell(
                      onTap: _saving ? null : _pickBirthdate,
                      borderRadius: BorderRadius.circular(NileRadius.md),
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Date of birth',
                          prefixIcon: Icon(
                            Icons.cake_outlined,
                            color: NileColors.txtTertiary,
                          ),
                          errorText: _tooYoung
                              ? 'You must be at least $minimumAge to use Nile'
                              : null,
                        ),
                        child: Text(
                          birthdate == null ? 'Tap to choose' : _formatted(birthdate),
                          style: NileTextStyles.bodyMd().copyWith(
                            color: birthdate == null
                                ? NileColors.txtTertiary
                                : NileColors.txtPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    const LegalConsentText(
                      action: 'continuing',
                      align: TextAlign.start,
                    ),
                    const SizedBox(height: 24),

                    FilledButton(
                      onPressed: (_saving || birthdate == null) ? null : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: NileSpacing.s16,
                        ),
                        backgroundColor: NileColors.volt,
                        foregroundColor: NileColors.onVolt,
                        disabledBackgroundColor: NileColors.bgRaised,
                      ),
                      child: _saving
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: NileColors.onVolt,
                              ),
                            )
                          : const Text('Agree and continue'),
                    ),
                    const SizedBox(height: 8),

                    // The only other way out of a blocking screen.
                    Center(
                      child: TextButton(
                        onPressed: _saving
                            ? null
                            : () => Supabase.instance.client.auth.signOut(),
                        child: Text(
                          'Sign out',
                          style: NileTextStyles.bodyMd().copyWith(
                            color: NileColors.txtTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
