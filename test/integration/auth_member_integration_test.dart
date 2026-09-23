@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `SupabaseAuthRepository.currentMember()` against a running local Supabase:
/// the member it returns carries the signed-in account's email, which
/// Settings > Account shows. A fake cannot check this — the address comes
/// from the Supabase session, not from anything the app stores.
///
/// Google itself is not reached: the accounts sign in with a password, and
/// currentMember() only reads the session that sign-in left behind.
///
/// Requires `docker compose run --rm supabase start`. Reuses cleo and una
/// (supabase/seed.sql); run with --concurrency=1 like the rest of the suite,
/// since signing in claims the account's active device.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

Future<SupabaseClient> signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

SupabaseAuthRepository repoOver(SupabaseClient c) =>
    SupabaseAuthRepository(c, GoogleSignIn.instance, googleWebClientId: 'c');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final clients = <SupabaseClient>[];
  tearDownAll(() async {
    for (final c in clients) {
      await c.dispose();
    }
  });

  for (final email in ['cleo@integration.test', 'una@integration.test']) {
    test('currentMember() carries $email, the signed-in account', () async {
      final client = await signedIn(email);
      clients.add(client);

      final result = await repoOver(client).currentMember();

      expect(result, isA<Ok<Member>>(), reason: '$result');
      final member = (result as Ok<Member>).value;
      expect(member.userId, client.auth.currentUser!.id);
      expect(member.email, email);
    });
  }
}
