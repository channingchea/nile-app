import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../router.dart';
import '../../services/human_check.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';
import '../../widgets/nile_logo.dart';
import '../../widgets/social_auth_buttons.dart';
import '../../widgets/suspended_dialog.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _loading = false;
  bool _obscurePass = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      await supabase.auth.signInWithPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
        // Required once Supabase captcha protection is enabled — it applies
        // to sign-in as well as sign-up.
        captchaToken: await HumanCheck.captchaToken(),
      );
      // Offers the OS password manager the chance to save the credentials.
      TextInput.finishAutofillContext();
      // _AuthGate in main.dart handles the navigation automatically
      // once the auth state stream emits a session.
    } on AuthException catch (e) {
      if (!mounted) {
        // nothing to show
      } else if (isSuspendedAuthError(e)) {
        // GoTrue's "User is banned" is not an error message to put in a
        // snackbar — it needs an explanation and a way to appeal (P3 #35).
        await showSuspendedDialog(context);
      } else {
        _showError(e.message);
      }
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
      body: NileMaxWidth(
        child: SafeArea(
          child: AutofillGroup(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s32, vertical: NileSpacing.s48),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Logo / wordmark ──────────────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          NileLogo(size: 'medium', height: 48),
                          const SizedBox(width: 10),
                          Text(
                            'Nile',
                            style: GoogleFonts.syne(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              color: NileColors.volt,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to continue',
                        textAlign: TextAlign.center,
                        style: NileTextStyles.bodyMd().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // ── Social sign-in ───────────────────────────────────────
                      // Above the form, mirroring signup — keeps the providers
                      // in the first screenful on short phones too.
                      const SocialAuthButtons(
                        dividerBelow: true,
                        dividerLabel: 'or sign in with email',
                      ),
                      const SizedBox(height: 24),

                      // ── Email ────────────────────────────────────────────────
                      TextFormField(
                        controller: _emailCtrl,
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email,
                        ],
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
                          if (v == null || v.trim().isEmpty) {
                            return 'Email is required';
                          }
                          if (!v.contains('@')) return 'Enter a valid email';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // ── Password ─────────────────────────────────────────────
                      TextFormField(
                        controller: _passCtrl,
                        autofillHints: const [AutofillHints.password],
                        obscureText: _obscurePass,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _signIn(),
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
                          if (v == null || v.isEmpty) {
                            return 'Password is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 8),

                      // ── Forgot password ──────────────────────────────────────
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            final email = _emailCtrl.text.trim();
                            context.push(
                              email.isEmpty
                                  ? NileRoutes.forgotPassword
                                  : '${NileRoutes.forgotPassword}?email='
                                      '${Uri.encodeComponent(email)}',
                            );
                          },
                          child: Text(
                            'Forgot password?',
                            style: NileTextStyles.bodyMd().copyWith(
                              color: NileColors.volt,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Sign in button ───────────────────────────────────────
                      FilledButton(
                        onPressed: _loading ? null : _signIn,
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
                            : const Text('Sign In'),
                      ),
                      const SizedBox(height: 24),

                      // ── Sign up link ─────────────────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Flexible: this row overflows at 375pt width
                          // (iPhone SE) once the button's padding is counted.
                          Flexible(
                            child: Text(
                              "Don't have an account?",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NileTextStyles.bodyMd().copyWith(
                                color: NileColors.txtTertiary,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => context.push(NileRoutes.signup),
                            child: Text(
                              'Sign Up',
                              style: NileTextStyles.bodyMd().copyWith(
                                color: NileColors.volt,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
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
