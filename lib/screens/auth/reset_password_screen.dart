import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';

/// Shown after the user opens a password-recovery link (main.dart pushes this on
/// [AuthChangeEvent.passwordRecovery]). Sets a new password on the recovery
/// session, after which the user is fully signed in.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await supabase.auth.updateUser(UserAttributes(password: _passCtrl.text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Password updated', style: NileTextStyles.bodyMd()),
          backgroundColor: NileColors.success,
        ),
      );
      Navigator.pop(context);
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
      body: NileMaxWidth(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s32,
              vertical: NileSpacing.s24,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: NileSpacing.s24),
                  Text('Set a new password', style: NileTextStyles.headingMd()),
                  const SizedBox(height: 8),
                  Text(
                    'Choose a new password for your account.',
                    style: NileTextStyles.bodyMd()
                        .copyWith(color: NileColors.txtTertiary),
                  ),
                  const SizedBox(height: 32),
                  NilePasswordField(
                    controller: _passCtrl,
                    label: 'New password',
                    obscure: _obscure,
                    onToggle: () => setState(() => _obscure = !_obscure),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Password is required';
                      if (v.length < 8) {
                        return 'Use at least 8 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  NilePasswordField(
                    controller: _confirmCtrl,
                    label: 'Confirm password',
                    obscure: _obscure,
                    onToggle: () => setState(() => _obscure = !_obscure),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    validator: (v) {
                      if (v != _passCtrl.text) return 'Passwords don\'t match';
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: _loading ? null : _save,
                    style: FilledButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: NileSpacing.s16),
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
                        : const Text('Update password'),
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

/// Shared obscured password input matching the app's field styling.
class NilePasswordField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;
  final FormFieldValidator<String>? validator;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  const NilePasswordField({
    super.key,
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
    this.validator,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      autocorrect: false,
      enableSuggestions: false,
      style: NileTextStyles.bodyMd(),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(Icons.lock_outline, color: NileColors.txtTertiary),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: NileColors.txtTertiary,
          ),
          onPressed: onToggle,
        ),
      ),
      validator: validator,
    );
  }
}
