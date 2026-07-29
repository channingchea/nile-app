import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'supabase_client.dart';

/// Thrown for real sign-in failures (network, configuration, rejected token).
/// User cancellation is NOT an exception — the methods return false instead.
class SocialAuthException implements Exception {
  final String message;
  SocialAuthException(this.message);
  @override
  String toString() => message;
}

/// Native Google / Apple sign-in via Supabase's `signInWithIdToken` path —
/// no browser redirect. Session propagation to _AuthGate is automatic through
/// the auth state stream.
class SocialAuthService {
  static bool _googleInitialized = false;

  /// Returns true on success, false if the user cancelled mid-flow.
  static Future<bool> signInWithGoogle() async {
    try {
      final signIn = GoogleSignIn.instance;
      if (!_googleInitialized) {
        // 7.x API: initialize() once, then authenticate() per attempt.
        await signIn.initialize(
          clientId: (!kIsWeb && Platform.isIOS) ? googleIosClientId : null,
          serverClientId: googleWebClientId,
        );
        _googleInitialized = true;
      }
      final account = await signIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw SocialAuthException('Google sign-in failed. Please try again.');
      }
      await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
      return true;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      throw SocialAuthException('Google sign-in failed. Please try again.');
    } on AuthException catch (e) {
      throw SocialAuthException(_friendlyAuthMessage(e));
    } on SocialAuthException {
      rethrow;
    } catch (_) {
      throw SocialAuthException('Google sign-in failed. Please try again.');
    }
  }

  /// Returns true on success, false if the user cancelled mid-flow.
  static Future<bool> signInWithApple() async {
    try {
      // Supabase verifies that sha256(rawNonce sent to it) matches the nonce
      // baked into Apple's identity token.
      final rawNonce = _generateNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
      final idToken = credential.identityToken;
      if (idToken == null) {
        throw SocialAuthException('Apple sign-in failed. Please try again.');
      }
      await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );

      // Apple returns the user's name ONLY on the very first authorization —
      // persist it now or lose it. Non-fatal if the write fails.
      final displayName = [credential.givenName, credential.familyName]
          .whereType<String>()
          .join(' ')
          .trim();
      final uid = supabase.auth.currentUser?.id;
      if (displayName.isNotEmpty && uid != null) {
        try {
          await supabase
              .from('profiles')
              .update({'display_name': displayName})
              .eq('id', uid);
        } catch (_) {
          // Keep the session — the user can set a display name in Edit Profile.
        }
      }
      return true;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return false;
      throw SocialAuthException('Apple sign-in failed. Please try again.');
    } on AuthException catch (e) {
      throw SocialAuthException(_friendlyAuthMessage(e));
    } on SocialAuthException {
      rethrow;
    } catch (_) {
      throw SocialAuthException('Apple sign-in failed. Please try again.');
    }
  }

  static String _friendlyAuthMessage(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('network') || msg.contains('connection')) {
      return 'No connection. Check your network and try again.';
    }
    return 'Could not complete sign-in. Please try again.';
  }

  static String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }
}
