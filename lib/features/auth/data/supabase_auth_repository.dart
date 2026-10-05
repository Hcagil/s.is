import 'dart:convert';
import 'dart:developer';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/auth_repository.dart';
import '../domain/member.dart';

/// What a member reads when sign-in fails. SDK and backend error text can carry
/// a token or an ID, so it never reaches the screen or the log: only the type
/// or code does.
const signInFailedMessage = 'Sign-in failed. Please try again.';
const signInCanceledMessage = 'Sign-in was cancelled. Please try again.';

/// [AuthRepository] backed by Google native sign-in and Supabase Auth.
final class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(
    this._client,
    this._google, {
    required this.googleWebClientId,
    this.useNonce = false,
  });

  final SupabaseClient _client;
  final GoogleSignIn _google;
  final String googleWebClientId;

  /// True on iOS: Google's iOS SDK puts a `nonce` claim in the ID token and
  /// Supabase rejects a token whose nonce the request does not echo. Android
  /// stays without one: nothing proves Play services embeds it, and a
  /// mismatch would break the production sign-in.
  final bool useNonce;
  bool _googleReady = false;
  String? _rawNonce;

  static const _scopes = ['https://www.googleapis.com/auth/userinfo.email'];

  @override
  bool get hasSession => _client.auth.currentSession != null;

  @override
  String? get userId => _client.auth.currentUser?.id;

  @override
  String? get sessionId {
    final token = _client.auth.currentSession?.accessToken;
    if (token == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, Object?>;
      final id = claims['session_id'];
      return id is String ? id : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<bool> get signedInChanges =>
      _client.auth.onAuthStateChange.map((s) => s.session != null).distinct();

  @override
  Future<Result<void>> signInWithGoogle() async {
    final GoogleSignInAccount user;
    try {
      // Initialised lazily so a missing Play Services only breaks sign-in,
      // never the whole app for an already signed-in member.
      if (!_googleReady) {
        // google_sign_in takes the nonce at initialize, which must run once,
        // so the nonce lives for the app process, not for each sign-in.
        // ponytail: one nonce per process; per-sign-in needs re-initialize,
        // which the plugin forbids.
        if (useNonce) {
          final random = Random.secure();
          _rawNonce = base64UrlEncode(
            List<int>.generate(32, (_) => random.nextInt(256)),
          ).replaceAll('=', '');
        }
        await _google.initialize(
          serverClientId: googleWebClientId,
          nonce: _rawNonce == null
              ? null
              : sha256.convert(utf8.encode(_rawNonce!)).toString(),
        );
        _googleReady = true;
      }
      user = await _google.authenticate(scopeHint: _scopes);
    } on GoogleSignInException catch (e) {
      return _googleFailure(e);
    } catch (e) {
      log('Google sign-in failed: ${e.runtimeType}', name: 'sis.auth');
      return const Err(ProviderFailure(signInFailedMessage));
    }
    final idToken = user.authentication.idToken;
    if (idToken == null) {
      log('Google sign-in returned no ID token', name: 'sis.auth');
      return const Err(ProviderFailure(signInFailedMessage));
    }
    try {
      final auth =
          await user.authorizationClient.authorizationForScopes(_scopes) ??
          await user.authorizationClient.authorizeScopes(_scopes);
      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: auth.accessToken,
        nonce: _rawNonce,
      );
      return const Ok(null);
    } on GoogleSignInException catch (e) {
      // The scope grant failed after the account was chosen.
      return _googleFailure(e);
    } on AuthRetryableFetchException catch (e) {
      // Offline, not a rejection: say so rather than blame the token.
      return Err(readableFailure(e));
    } on AuthException catch (e) {
      // e.message can hold the token's audience or the token itself.
      log(
        'Supabase rejected the Google token: ${e.statusCode}',
        name: 'sis.auth',
      );
      // The sign-up hook refuses an address that is not invited (403).
      if (e.statusCode == '403') return const Err(DeniedFailure());
      return const Err(ProviderFailure(signInFailedMessage));
    }
  }

  Err<void> _googleFailure(GoogleSignInException e) {
    // A Credential Manager "cancellation" after account selection usually
    // means the Android OAuth client / SHA-1 is not registered, hence the
    // code in the log.
    log('Google sign-in failed: ${e.code.name}', name: 'sis.auth');
    final canceled =
        e.code == GoogleSignInExceptionCode.canceled ||
        e.code == GoogleSignInExceptionCode.interrupted;
    return Err(
      ProviderFailure(
        canceled ? signInCanceledMessage : signInFailedMessage,
        userCanceled: canceled,
      ),
    );
  }

  @override
  Future<Result<bool>> activateSession() async {
    try {
      return Ok(await _client.rpc('activate_session') == true);
    } catch (e) {
      return Err(readableFailure(e));
    }
  }

  @override
  Future<Result<Member>> currentMember() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return const Err(DeniedFailure());
    try {
      final row = await _client
          .from('profiles')
          .select('user_id, display_name, tag')
          .eq('user_id', uid)
          .single()
          .retriedOnce();
      return Ok(
        Member(
          userId: row['user_id'] as String,
          displayName: row['display_name'] as String,
          tag: row['tag'] as String?,
          email: _client.auth.currentUser?.email,
        ),
      );
    } catch (e) {
      return Err(readableFailure(e));
    }
  }

  @override
  Future<void> signOut() async {
    // Best effort: the caller clears local state regardless of the outcome.
    try {
      await _google.signOut();
    } catch (_) {}
    try {
      await _client.auth.signOut();
    } catch (_) {
      // gotrue rethrows network errors before clearing the stored session;
      // make sure this device forgets it regardless.
      try {
        await _client.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
    }
  }
}
