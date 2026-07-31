import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/profile_service.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';

/// Shown after an OAuth sign-in (Google/Apple) while the account still holds
/// an auto-generated username. Blocking — _AuthGate routes here before
/// onboarding and there is no skip option.
class ClaimUsernameScreen extends StatefulWidget {
  const ClaimUsernameScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<ClaimUsernameScreen> createState() => _ClaimUsernameScreenState();
}

enum _Availability { unknown, checking, available, taken }

class _ClaimUsernameScreenState extends State<ClaimUsernameScreen> {
  static final _usernameRegExp = RegExp(r'^[a-z0-9_]{3,20}$');

  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();

  Timer? _debounce;
  _Availability _availability = _Availability.unknown;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Prefill with the generated placeholder as a suggestion.
    ProfileService.fetchCurrentProfile().then((profile) {
      if (mounted && profile != null && _usernameCtrl.text.isEmpty) {
        _usernameCtrl.text = profile.username;
        _onChanged(profile.username);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _usernameCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final username = value.trim().toLowerCase();
    if (!_usernameRegExp.hasMatch(username)) {
      setState(() => _availability = _Availability.unknown);
      return;
    }
    setState(() => _availability = _Availability.checking);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final uid = supabase.auth.currentUser?.id;
      try {
        final available = await ProfileService.isUsernameAvailable(
          username,
          excludeUserId: uid,
        );
        if (mounted && _usernameCtrl.text.trim().toLowerCase() == username) {
          setState(() => _availability =
              available ? _Availability.available : _Availability.taken);
        }
      } catch (_) {
        // Network hiccup on the live check — submit still validates server-side.
        if (mounted) setState(() => _availability = _Availability.unknown);
      }
    });
  }

  Future<void> _claim() async {
    if (!_formKey.currentState!.validate()) return;
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    // Otherwise the keyboard follows us into the onboarding steps.
    FocusManager.instance.primaryFocus?.unfocus();

    setState(() => _saving = true);
    try {
      await ProfileService.updateProfile(
        userId: uid,
        username: _usernameCtrl.text.trim().toLowerCase(),
        usernameIsProvisional: false,
      );
      widget.onDone();
    } on UsernameTakenException {
      if (mounted) {
        setState(() => _availability = _Availability.taken);
        _showError('That username is taken. Please choose another.');
      }
    } catch (_) {
      if (mounted) _showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: NileTextStyles.bodyMd()),
        backgroundColor: NileColors.error,
      ),
    );
  }

  Widget? _availabilitySuffix() {
    switch (_availability) {
      case _Availability.checking:
        return const Padding(
          padding: EdgeInsets.all(NileSpacing.s12),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _Availability.available:
        return Icon(Icons.check_circle_outline, color: NileColors.volt);
      case _Availability.taken:
        return Icon(Icons.error_outline, color: NileColors.error);
      case _Availability.unknown:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Blocking screen: no back navigation, no skip.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: NileColors.bgPage,
        body: NileMaxWidth(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s32,
                  vertical: NileSpacing.s24,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Claim your username',
                          style: NileTextStyles.displayMd()),
                      const SizedBox(height: 8),
                      Text(
                        "This is how you'll appear across Nile. "
                        'You can change it later in Edit Profile.',
                        style: NileTextStyles.bodyMd().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        controller: _usernameCtrl,
                        autofocus: true,
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                        onChanged: _onChanged,
                        onFieldSubmitted: (_) => _claim(),
                        style: NileTextStyles.bodyMd(),
                        decoration: InputDecoration(
                          labelText: 'Username',
                          hintText: 'lowercase, no spaces',
                          prefixIcon: Icon(
                            Icons.alternate_email,
                            color: NileColors.txtTertiary,
                          ),
                          suffixIcon: _availabilitySuffix(),
                        ),
                        validator: (v) {
                          final username = (v ?? '').trim().toLowerCase();
                          if (username.isEmpty) return 'Username is required';
                          if (username.length < 3) return 'At least 3 characters';
                          if (!_usernameRegExp.hasMatch(username)) {
                            return '3–20 chars: letters, numbers, underscores';
                          }
                          if (_availability == _Availability.taken) {
                            return 'That username is taken';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 32),
                      FilledButton(
                        onPressed: _saving ? null : _claim,
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
                            : const Text('Continue'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
