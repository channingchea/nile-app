import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_client.dart';

/// Result of starting TOTP enrollment: what the enroll screen needs to render
/// the QR code and manual key, plus the [factorId] used to verify.
class MfaEnrollment {
  final String factorId;

  /// SVG markup for the QR code (render with flutter_svg's `SvgPicture.string`).
  final String qrCodeSvg;

  /// The manual-entry key, shown for users who can't scan the QR.
  final String secret;

  /// The full `otpauth://` URI (secret embedded), if a caller needs it.
  final String uri;

  const MfaEnrollment({
    required this.factorId,
    required this.qrCodeSvg,
    required this.secret,
    required this.uri,
  });
}

/// Remaining / used backup recovery-code counts, from the `mfa-recovery`
/// Edge Function `status` action.
class RecoveryCodeStatus {
  final int total;
  final int used;
  final int remaining;

  const RecoveryCodeStatus({
    required this.total,
    required this.used,
    required this.remaining,
  });
}

/// Single seam for all Multi-Factor Auth work, wrapping Supabase native MFA
/// (`supabase.auth.mfa.*`) plus our custom backup-code Edge Function
/// (`mfa-recovery`). Screens stay thin and factor-type-agnostic.
///
/// This pass ships TOTP only; every enroll/challenge path takes an optional
/// [FactorType] defaulting to `totp` so a `phone` factor drops in later without
/// touching call sites.
class MfaService {
  const MfaService._();

  static GoTrueMFAApi get _mfa => supabase.auth.mfa;

  // ---- Factors / assurance level -------------------------------------------

  /// All verified factors on the account. Empty when 2FA is off.
  static Future<List<Factor>> verifiedFactors() async {
    final res = await _mfa.listFactors();
    return res.all.where((f) => f.status == FactorStatus.verified).toList();
  }

  /// Whether the user has any verified factor (i.e. 2FA is enabled).
  static Future<bool> hasVerifiedFactor() async =>
      (await verifiedFactors()).isNotEmpty;

  /// True when the current session is authenticated (aal1) but a verified
  /// factor requires a second step (nextLevel aal2). Drives login/cold-start
  /// routing to the challenge screen.
  static bool needsChallenge() {
    final aal = _mfa.getAuthenticatorAssuranceLevel();
    return aal.currentLevel == AuthenticatorAssuranceLevels.aal1 &&
        aal.nextLevel == AuthenticatorAssuranceLevels.aal2;
  }

  /// True once the session has cleared the second step (aal2).
  static bool isElevated() =>
      _mfa.getAuthenticatorAssuranceLevel().currentLevel ==
      AuthenticatorAssuranceLevels.aal2;

  // ---- Enroll --------------------------------------------------------------

  /// Begin enrollment for a new (unverified) factor and return the data needed
  /// to display the QR / manual key. Call [verify] with a code to activate it.
  static Future<MfaEnrollment> enroll({
    FactorType factorType = FactorType.totp,
    String friendlyName = 'Nile',
  }) async {
    final res = await _mfa.enroll(
      factorType: factorType,
      friendlyName: friendlyName,
    );
    final totp = res.totp;
    return MfaEnrollment(
      factorId: res.id,
      qrCodeSvg: totp?.qrCode ?? '',
      secret: totp?.secret ?? '',
      uri: totp?.uri ?? '',
    );
  }

  /// Verify a factor with a code from the authenticator app. Used both to
  /// finish enrollment and to re-authorize sensitive actions (disable). On
  /// success the session is elevated to aal2. Throws on a wrong/expired code.
  static Future<void> verify({
    required String factorId,
    required String code,
  }) async {
    await _mfa.challengeAndVerify(factorId: factorId, code: code);
  }

  /// Discard a factor. Used to clean up an abandoned unverified enrollment and
  /// to turn 2FA off (after a fresh [verify]).
  static Future<void> unenroll(String factorId) async {
    await _mfa.unenroll(factorId);
  }

  /// Turn off 2FA entirely: unenroll every factor. Caller must have completed a
  /// fresh [verify] first (re-challenge before disable).
  static Future<void> unenrollAll() async {
    for (final f in await verifiedFactors()) {
      await _mfa.unenroll(f.id);
    }
  }

  // ---- Backup recovery codes (custom Edge Function) ------------------------

  /// Generate a fresh set of one-time backup codes, returned in plaintext
  /// exactly once. Any previous codes are invalidated. Show these on the
  /// backup-codes screen and require the user to confirm they saved them.
  static Future<List<String>> generateRecoveryCodes() async {
    final data = await _invokeRecovery('generate');
    return (data['codes'] as List).cast<String>();
  }

  /// Remaining / used counts for the Security section.
  static Future<RecoveryCodeStatus> recoveryStatus() async {
    final data = await _invokeRecovery('status');
    return RecoveryCodeStatus(
      total: (data['total'] as num).toInt(),
      used: (data['used'] as num).toInt(),
      remaining: (data['remaining'] as num).toInt(),
    );
  }

  /// Delete all of the user's backup codes. Called when turning 2FA off so no
  /// stale codes linger.
  static Future<void> clearRecoveryCodes() async {
    await _invokeRecovery('clear');
  }

  /// Consume a backup code during the lost-authenticator recovery flow. On
  /// success the server marks the code used and unenrolls the user's factors,
  /// leaving the session at aal1 so the client can re-enroll. Throws on an
  /// invalid or already-used code.
  static Future<void> consumeRecoveryCode(String code) async {
    await _invokeRecovery('consume', extra: {'code': code});
  }

  static Future<Map<String, dynamic>> _invokeRecovery(
    String action, {
    Map<String, dynamic>? extra,
  }) async {
    final res = await supabase.functions.invoke(
      'mfa-recovery',
      body: {'action': action, ...?extra},
    );
    final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
    if (res.status != 200) {
      throw Exception(data['error'] ?? 'Recovery request failed');
    }
    return data;
  }
}
