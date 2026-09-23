import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../domain/auth_repository.dart';
import '../domain/member.dart';

/// [AuthRepository] backed by Google native sign-in and Supabase Auth.
final class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(
    this._client,
    this._google, {
    required this.googleWebClientId,
  });

  final SupabaseClient _client;
  final GoogleSignIn _google;
  final String googleWebClientId;
  bool _googleReady = false;

  static const _scopes = ['https://www.googleapis.com/auth/userinfo.email'];

  @override
  bool get hasSession => _client.auth.currentSession != null;

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
        await _google.initialize(serverClientId: googleWebClientId);
        _googleReady = true;
      }
      user = await _google.authenticate(scopeHint: _scopes);
    } on GoogleSignInException catch (e) {
      // A Credential Manager "cancellation" after account selection usually
      // means the Android OAuth client / SHA-1 is not registered.
      final canceled =
          e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted;
      return Err(
        ProviderFailure(
          'Google sign-in ${e.code.name}: ${e.description ?? 'no details'}',
          userCanceled: canceled,
        ),
      );
    } catch (e) {
      return Err(ProviderFailure('Google sign-in unavailable: $e'));
    }
    final idToken = user.authentication.idToken;
    if (idToken == null) {
      return const Err(ProviderFailure('Google did not return an ID token.'));
    }
    try {
      final auth =
          await user.authorizationClient.authorizationForScopes(_scopes) ??
          await user.authorizationClient.authorizeScopes(_scopes);
      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: auth.accessToken,
      );
      return const Ok(null);
    } on AuthException catch (e) {
      return Err(
        ProviderFailure('Supabase rejected the Google token: ${e.message}'),
      );
    }
  }

  @override
  Future<Result<bool>> activateSession() async {
    try {
      return Ok(await _client.rpc('activate_session') == true);
    } on PostgrestException catch (e) {
      return Err(NetworkFailure(e.message));
    } catch (e) {
      return Err(NetworkFailure(e.toString()));
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
          .single();
      return Ok(
        Member(
          userId: row['user_id'] as String,
          displayName: row['display_name'] as String,
          tag: row['tag'] as String?,
          email: _client.auth.currentUser?.email,
        ),
      );
    } on PostgrestException catch (e) {
      return Err(NetworkFailure(e.message));
    } catch (e) {
      // Network failures surface as ClientException, not PostgrestException.
      return Err(NetworkFailure('$e'));
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
