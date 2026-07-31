import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config.dart';
import '../../services/human_check.dart';
import '../../services/profile_service.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';
import '../../widgets/nile_logo.dart';
import '../../widgets/social_auth_buttons.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  static final _usernameRegExp = RegExp(r'^[a-z0-9_]+$');
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _loading = false;
  bool _obscurePass = true;
  bool _obscureConf = true;
  bool _submitted = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      // Username availability pre-check — a collision inside the signup
      // trigger would otherwise surface as an opaque server error.
      final username = _usernameCtrl.text.trim().toLowerCase();
      if (!await ProfileService.isUsernameAvailable(username)) {
        if (mounted) {
          _showError('That username is taken. Please choose another.');
          setState(() => _loading = false);
        }
        return;
      }

      // Bot protection: invisible captcha + device attestation (both null
      // until configured — see human_check.dart).
      final captcha = await HumanCheck.captchaToken();
      final attestation = await HumanCheck.attestationToken();

      final response = await supabase.auth.signUp(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
        captchaToken: captcha,
        // Without this the confirmation email falls back to the project's
        // Site URL (localhost) and the link dead-ends in a browser.
        emailRedirectTo: emailConfirmRedirect,
        data: {
          // Passed to raw_user_meta_data and picked up by the
          // handle_new_user trigger to populate profiles.
          'username': _usernameCtrl.text.trim().toLowerCase(),
          'display_name': _nameCtrl.text.trim(),
          // Verified (and stripped) by the before-user-created auth hook.
          'app_check_token': ?attestation,
        },
      );

      if (!mounted) return;

      if (response.session != null) {
        // Email confirmation is off — session created immediately.
        // _AuthGate will automatically navigate to HomeScreen.
      } else {
        // Email confirmation is on — swap to the full-screen confirmation view.
        setState(() => _submitted = true);
      }
    } on AuthException catch (e) {
      // A race on the username pre-check still fails inside the signup
      // trigger and surfaces as a generic database error — translate it.
      final msg = e.message.toLowerCase().contains('database error')
          ? 'That username may already be taken. Please try another.'
          : e.message;
      if (mounted) _showError(msg);
    } catch (_) {
      if (mounted) _showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: NileColors.bgPage,
        leading: _submitted
            ? null
            : IconButton(
                icon: Icon(
                  Icons.arrow_back,
                  color: NileColors.txtSecondary,
                ),
                onPressed: () => Navigator.pop(context),
              ),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: _submitted ? _buildCheckEmailView() : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildCheckEmailView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s32, vertical: NileSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Icon(
            Icons.mark_email_read_outlined,
            size: 80,
            color: NileColors.volt,
          ),
          const SizedBox(height: 32),
          Text(
            'Check your email',
            textAlign: TextAlign.center,
            style: NileTextStyles.displayMd(),
          ),
          const SizedBox(height: 16),
          Text(
            'We sent a confirmation link to ${_emailCtrl.text.trim()}. '
            'Tap the link to finish setting up your account.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.onVolt,
            ),
            child: const Text('Return to sign in'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s32, vertical: NileSpacing.s16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ───────────────────────────────────────────────
              Center(child: NileLogo(size: 'medium', height: 48)),
              const SizedBox(height: 24),
              Text('Create account', style: NileTextStyles.displayMd()),
              const SizedBox(height: 8),
              Text(
                'Join Nile to create and watch live events.',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
              const SizedBox(height: 40),

              // ── Username ─────────────────────────────────────────────
              TextFormField(
                controller: _usernameCtrl,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                style: NileTextStyles.bodyMd(),
                decoration: InputDecoration(
                  labelText: 'Username',
                  hintText: 'lowercase, no spaces',
                  prefixIcon: Icon(
                    Icons.alternate_email,
                    color: NileColors.txtTertiary,
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Username is required';
                  }
                  if (v.trim().length < 3) return 'At least 3 characters';
                  if (!_usernameRegExp.hasMatch(v.trim().toLowerCase())) {
                    return 'Only letters, numbers, and underscores';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Display name ─────────────────────────────────────────
              TextFormField(
                controller: _nameCtrl,
                textInputAction: TextInputAction.next,
                style: NileTextStyles.bodyMd(),
                decoration: InputDecoration(
                  labelText: 'Display name',
                  hintText: 'How you appear to others',
                  prefixIcon: Icon(
                    Icons.person_outline,
                    color: NileColors.txtTertiary,
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Display name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Email ────────────────────────────────────────────────
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                style: NileTextStyles.bodyMd(),
                decoration: InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(
                    Icons.mail_outline,
                    color: NileColors.txtTertiary,
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Email is required';
                  if (!v.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Password ─────────────────────────────────────────────
              TextFormField(
                controller: _passCtrl,
                obscureText: _obscurePass,
                textInputAction: TextInputAction.next,
                style: NileTextStyles.bodyMd(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(
                    Icons.lock_outline,
                    color: NileColors.txtTertiary,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePass
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: NileColors.txtTertiary,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Password is required';
                  if (v.length < 8) return 'At least 8 characters';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Confirm password ─────────────────────────────────────
              TextFormField(
                controller: _confirmCtrl,
                obscureText: _obscureConf,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _signUp(),
                style: NileTextStyles.bodyMd(),
                decoration: InputDecoration(
                  labelText: 'Confirm password',
                  prefixIcon: Icon(
                    Icons.lock_outline,
                    color: NileColors.txtTertiary,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConf
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: NileColors.txtTertiary,
                    ),
                    onPressed: () =>
                        setState(() => _obscureConf = !_obscureConf),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) {
                    return 'Please confirm your password';
                  }
                  if (v != _passCtrl.text) return 'Passwords do not match';
                  return null;
                },
              ),
              const SizedBox(height: 32),

              // ── Create account button ────────────────────────────────
              FilledButton(
                onPressed: _loading ? null : _signUp,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                  backgroundColor: NileColors.volt,
                  foregroundColor: NileColors.onVolt,
                  disabledBackgroundColor: NileColors.bgRaised,
                ),
                child: _loading
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.onVolt,
                        ),
                      )
                    : const Text('Create Account'),
              ),
              const SizedBox(height: 24),

              // ── Social sign-in ───────────────────────────────────────
              const SocialAuthButtons(),
              const SizedBox(height: 24),

              // ── Back to sign in ──────────────────────────────────────
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Already have an account? Sign in',
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
    );
  }
}
