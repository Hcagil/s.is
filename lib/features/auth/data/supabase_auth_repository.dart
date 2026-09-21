import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../domain/auth_repository.dart';
import '../domain/member.dart';

/// [AuthRepository] backed by Google native sign-in and Supabase Auth.
final class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client, this._google);

  final SupabaseClient _client;
  final GoogleSignIn _google;

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
          .select('user_id, display_name')
          .eq('user_id', uid)
          .single();
      return Ok(
        Member(
          userId: row['user_id'] as String,
          displayName: row['display_name'] as String,
        ),
      );
    } on PostgrestException catch (e) {
      return Err(NetworkFailure(e.message));
    }
  }

  @override
  Future<void> signOut() async {
    await _google.signOut();
    await _client.auth.signOut();
  }
}
