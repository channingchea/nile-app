import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config.dart';
import '../../services/human_check.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';

/// Collects an email and sends a Supabase password-recovery email. The link in
/// that email opens the app via the `nile://reset-callback` deep link, which the
/// SDK turns into an [AuthChangeEvent.passwordRecovery] event handled in main.dart.
class ForgotPasswordScreen extends StatefulWidget {
  final String? initialEmail;
  const ForgotPasswordScreen({super.key, this.initialEmail});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _emailCtrl = TextEditingController(text: widget.initialEmail ?? '');

  bool _loading = false;
  bool _sent = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await supabase.auth.resetPasswordForEmail(
        _emailCtrl.text.trim(),
        redirectTo: passwordResetRedirect,
        // Required once Supabase captcha protection is enabled.
        captchaToken: await HumanCheck.captchaToken(),
      );
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (e) {
      if (mounted) _showError(e.message);
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
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: NileColors.txtPrimary),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s32,
              vertical: NileSpacing.s24,
            ),
            child: _sent ? _buildSent() : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reset password', style: NileTextStyles.headingMd()),
          const SizedBox(height: 8),
          Text(
            'Enter your email and we\'ll send you a link to reset your password.',
            style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtTertiary),
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            onFieldSubmitted: (_) => _send(),
            style: NileTextStyles.bodyMd(),
            decoration: InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.mail_outline, color: NileColors.txtTertiary),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Email is required';
              if (!v.contains('@')) return 'Enter a valid email';
              return null;
            },
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _loading ? null : _send,
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
                : const Text('Send reset link'),
          ),
        ],
      ),
    );
  }

  Widget _buildSent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.mark_email_read_outlined, size: 56, color: NileColors.volt),
        const SizedBox(height: 24),
        Text('Check your email', style: NileTextStyles.headingMd()),
        const SizedBox(height: 8),
        Text(
          'If an account exists for ${_emailCtrl.text.trim()}, you\'ll receive a '
          'link to reset your password. Open it on this device to continue.',
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtTertiary),
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.onVolt,
          ),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }
}
