import 'dart:convert';
import 'dart:developer';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/account_deletion_repository.dart';
import '../domain/auth_repository.dart';

/// [AccountDeletionRepository] backed by the `request_account_deletion` RPC and the `apple-revoke` edge function.
class SupabaseAccountDeletionRepository implements AccountDeletionRepository {
  SupabaseAccountDeletionRepository(this._client, this._auth);

  final SupabaseClient _client;
  final AuthRepository _auth;

  @override
  Future<Result<DateTime>> requestDeletion() async {
    final isApple =
        _client.auth.currentUser?.identities?.any(
          (i) => i.provider == 'apple',
        ) ??
        false;

    if (isApple) {
      final codeResult = await _appleAgain();
      if (codeResult is Err<String>) return Err(codeResult.failure);
      final code = (codeResult as Ok<String>).value;

      try {
        await _client.functions.invoke(
          'apple-revoke',
          body: {'authorization_code': code},
        );
      } catch (e) {
        log('Apple revoke failed', name: 'sis.auth');
        return Err(ProviderFailure(failureStrings.failDeleteAccountApple));
      }
    } else {
      final r = await _auth.signInWithGoogle();
      if (r is Err<void>) return Err(r.failure);
    }

    await _auth.activateSession();

    final String answer;
    try {
      answer = await _client.rpc('request_account_deletion') as String;
    } on PostgrestException catch (e) {
      // 42501 not permitted; P0001 REAUTH or APPLE_REVOKE_REQUIRED
      if (e.message == 'REAUTH') return const Err(ReauthRequiredFailure());
      if (e.message == 'APPLE_REVOKE_REQUIRED') {
        return Err(ProviderFailure(failureStrings.failDeleteAccountApple));
      }
      return Err(
        e.code == '42501'
            ? ProviderFailure(failureStrings.failDeleteAccount)
            : readableFailure(e),
      );
    } catch (e) {
      return Err(readableFailure(e));
    }

    final due = DateTime.parse(answer);
    await _auth.signOut();
    return Ok(due.toLocal());
  }

  @override
  Future<Result<Set<String>>> missingUsers(List<String> ids) async {
    final missing = <String>{};
    try {
      for (var i = 0; i < ids.length; i += 200) {
        final end = i + 200 > ids.length ? ids.length : i + 200;
        final answer = await _client.rpc(
          'missing_users',
          params: {'ids': ids.sublist(i, end)},
        );
        missing.addAll((answer as List).cast<String>());
      }
    } catch (e) {
      return Err(readableFailure(e));
    }
    return Ok(missing);
  }

  /// Signs in with Apple again (a fresh session) and returns the one-time authorization code Apple's revoke needs.
  Future<Result<String>> _appleAgain() async {
    final random = Random.secure();
    final rawNonce = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      log('Apple sign-in failed: ${e.code.name}', name: 'sis.auth');
      final canceled = e.code == AuthorizationErrorCode.canceled;
      return Err(
        ProviderFailure(
          canceled
              ? failureStrings.failSignInCanceled
              : failureStrings.failSignIn,
          userCanceled: canceled,
        ),
      );
    } catch (e) {
      log('Apple sign-in failed: ${e.runtimeType}', name: 'sis.auth');
      return Err(ProviderFailure(failureStrings.failSignIn));
    }

    final idToken = credential.identityToken;
    if (idToken == null) {
      return Err(ProviderFailure(failureStrings.failSignIn));
    }

    try {
      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      return Ok(credential.authorizationCode);
    } on AuthRetryableFetchException catch (e) {
      return Err(readableFailure(e));
    } on AuthException catch (e) {
      log(
        'Supabase rejected the Apple token: ${e.statusCode}',
        name: 'sis.auth',
      );
      return Err(ProviderFailure(failureStrings.failSignIn));
    }
  }
}
