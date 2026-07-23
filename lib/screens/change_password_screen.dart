import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/human_check.dart';
import '../services/supabase_client.dart';
import '../theme.dart';
import 'auth/reset_password_screen.dart' show NilePasswordField;

/// In-app password change for a signed-in user. Re-verifies the current password
/// before setting the new one.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _loading = false;
  bool _obscureCurrent = true;
  bool _obscureNew = true;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final email = supabase.auth.currentUser?.email;
    if (email == null) {
      _showError('You must be signed in to change your password.');
      return;
    }
    setState(() => _loading = true);
    try {
      // Re-authenticate to confirm the current password is correct.
      // captchaToken required once Supabase captcha protection is enabled.
      await supabase.auth.signInWithPassword(
        email: email,
        password: _currentCtrl.text,
        captchaToken: await HumanCheck.captchaToken(),
      );
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
      // A failed re-auth surfaces here as invalid credentials.
      if (mounted) {
        _showError(
          e.statusCode == '400' ? 'Current password is incorrect.' : e.message,
        );
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
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: NileColors.txtPrimary),
        title: Text('Change password', style: NileTextStyles.headingSm()),
      ),
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
                  NilePasswordField(
                    controller: _currentCtrl,
                    label: 'Current password',
                    obscure: _obscureCurrent,
                    onToggle: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Current password is required'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  NilePasswordField(
                    controller: _passCtrl,
                    label: 'New password',
                    obscure: _obscureNew,
                    onToggle: () => setState(() => _obscureNew = !_obscureNew),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Password is required';
                      if (v.length < 8) return 'Use at least 8 characters';
                      if (v == _currentCtrl.text) {
                        return 'New password must be different';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  NilePasswordField(
                    controller: _confirmCtrl,
                    label: 'Confirm new password',
                    obscure: _obscureNew,
                    onToggle: () => setState(() => _obscureNew = !_obscureNew),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    validator: (v) =>
                        v != _passCtrl.text ? 'Passwords don\'t match' : null,
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
