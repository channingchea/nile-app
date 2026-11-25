import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config.dart';
import '../../services/age_signals_service.dart';
import '../../services/compliance_service.dart';
import '../../theme.dart';
import '../../widgets/legal_links.dart';

/// Birthdate + Terms acceptance, for every account that has neither on file:
/// Google/Apple sign-ups (whose provider hands us no birthday), and everyone
/// who joined before the age gate existed. Email sign-ups answer both on the
/// signup form and never see this.
///
/// The store is asked first (P4). A bracket from the App Store is age
/// assurance — for a child in Family Sharing it comes from their parent —
/// while a typed birthday is only a claim, and Texas, Utah and Louisiana all
/// want the former. When the store can't or won't answer, the picker below is
/// the fallback, which is also the only path on iOS 25 and earlier.
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
  /// True while the system sheet is up. Nothing else is drawn underneath it.
  bool _askingStore = false;

  /// Set once the store vouches for a bracket — the picker is then skipped.
  AgeSignal? _assured;

  DateTime? _birthdate;
  bool _saving = false;
  bool _tooYoung = false;

  /// The store said "under 13". Unlike a mistyped birthday this is not
  /// recoverable by trying again, so the picker is never offered after it.
  bool _refusedByStore = false;

  @override
  void initState() {
    super.initState();
    if (AgeSignalsService.supported) _askStore();
  }

  Future<void> _askStore() async {
    setState(() => _askingStore = true);
    // Gates at 13 / 16 / 18: the account minimum, then the two brackets the
    // state laws draw their own lines at.
    final signal = await AgeSignalsService.request(gates: const [13, 16, 18]);
    if (!mounted) return;
    setState(() {
      _askingStore = false;
      if (signal.isUnderMinimum) {
        _refusedByStore = true;
      } else if (signal.isShared) {
        _assured = signal;
      }
      // declined / unsupported fall through to the picker.
    });
  }

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
    if (_saving) return;
    final assured = _assured;
    final birthdate = _birthdate;
    if (assured == null) {
      if (birthdate == null) return;
      if (!ComplianceService.isOldEnough(birthdate)) {
        setState(() => _tooYoung = true);
        return;
      }
    }

    setState(() => _saving = true);
    try {
      if (assured != null) {
        await ComplianceService.recordAssuredAge(assured, source: 'app_store');
      } else {
        await ComplianceService.recordConsent(birthdate!);
      }
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
                child: _body(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_askingStore) return _checkingView();
    if (_refusedByStore) return _refusedView();
    return _form();
  }

  Widget _checkingView() {
    return Column(
      children: [
        const SizedBox(height: NileSpacing.s32),
        const CircularProgressIndicator(),
        const SizedBox(height: NileSpacing.s24),
        Text('Checking with the App Store', style: NileTextStyles.headingSm()),
        const SizedBox(height: NileSpacing.s8),
        Text(
          "So you don't have to type your birthday.",
          textAlign: TextAlign.center,
          style: NileTextStyles.bodySm().copyWith(color: NileColors.txtTertiary),
        ),
      ],
    );
  }

  Widget _refusedView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.lock_outline, size: 48, color: NileColors.txtTertiary),
        const SizedBox(height: NileSpacing.s24),
        Text('Nile is for $minimumAge and over', style: NileTextStyles.displayMd()),
        const SizedBox(height: NileSpacing.s8),
        Text(
          "Your App Store account says you're under $minimumAge, so we can't set "
          'up a Nile account yet. If that\'s wrong, the age on your Apple '
          'Account is what needs correcting — a parent or guardian can change '
          'it in Family Sharing.',
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtTertiary),
        ),
        const SizedBox(height: NileSpacing.s32),
        FilledButton(
          onPressed: () => Supabase.instance.client.auth.signOut(),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.onVolt,
          ),
          child: const Text('Sign out'),
        ),
      ],
    );
  }

  Widget _form() {
    final assured = _assured;
    final birthdate = _birthdate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('One quick thing', style: NileTextStyles.displayMd()),
        const SizedBox(height: 8),
        Text(
          assured != null
              ? 'Just agree to our terms and you\'re in.'
              : 'Nile is for people $minimumAge and over. Confirm your date of '
                  'birth and agree to our terms to keep going. '
                  'Your birthday is private — nobody else sees it.',
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtTertiary),
        ),
        const SizedBox(height: 32),

        if (assured != null)
          _assuredCard(assured)
        else ...[
          // Not a TextFormField: a typed date is a mess to validate and a
          // picker makes "I'm 12" a deliberate act rather than a typo.
          InkWell(
            onTap: _saving ? null : _pickBirthdate,
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Date of birth',
                prefixIcon: Icon(Icons.cake_outlined, color: NileColors.txtTertiary),
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
        ],
        const SizedBox(height: 24),

        const LegalConsentText(action: 'continuing', align: TextAlign.start),
        const SizedBox(height: 24),

        FilledButton(
          onPressed: (_saving || (assured == null && birthdate == null))
              ? null
              : _submit,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
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
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtTertiary),
            ),
          ),
        ),
      ],
    );
  }

  /// What the store told us, said back plainly. The exact bracket matters to
  /// the user — "over 18" and "13 or over" lead to different Niles later — so
  /// it is shown rather than hidden behind a tick.
  Widget _assuredCard(AgeSignal signal) {
    final lower = signal.lowerBound;
    final label = lower == null
        ? 'Your age is confirmed'
        : signal.upperBound == null
            ? 'Your App Store account confirms you\'re $lower or over'
            : 'Your App Store account confirms you\'re $lower–${signal.upperBound}';
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, color: NileColors.volt, size: 22),
          const SizedBox(width: NileSpacing.s12),
          Expanded(child: Text(label, style: NileTextStyles.bodyMd())),
        ],
      ),
    );
  }
}
