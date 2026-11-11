@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';

import '../support/service_key.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _allowed = 'removed-status@integration.test';
const _stranger = 'removed-status-stranger@integration.test';

typedef Phone = ({SupabaseAuthRepository repo, SupabaseClient client});

/// Sign‑in a user and return the repository that will be used to activate
/// the session.  The repository is constructed with a fresh SupabaseClient
/// that is signed in to the supplied [email].
Future<Phone> _repo(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign‑in failed');
  return (
    repo: SupabaseAuthRepository(
      client,
      GoogleSignIn.instance,
      googleWebClientId: 'c',
    ),
    client: client,
  );
}

Future<void> _ensureUninvited(String email) async {
  await ensureUninvitedUser(_url, email, localTestPassword);
  await setLocalTestPassword(_url, email, localTestPassword);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUpAll(() async {
    await setLocalTestPassword(_url, _allowed, localTestPassword);
    await _ensureUninvited(_stranger);
  });

  group('removed status activation', () {
    test('allowed account activates session successfully', () async {
      final phone = await _repo(_allowed);
      final r = await phone.repo.activateSession();
      expect(r, isA<Ok<bool>>());
      expect((r as Ok<bool>).value, isTrue);
      await phone.client.dispose();
    });

    test('second client replaces first, first becomes replaced', () async {
      // First client
      final a = await _repo(_allowed);
      final rA1 = await a.repo.activateSession();
      expect(rA1, isA<Ok<bool>>());
      expect((rA1 as Ok<bool>).value, isTrue);

      // Second client
      final b = await _repo(_allowed);
      final rB = await b.repo.activateSession();
      expect(rB, isA<Ok<bool>>());
      expect((rB as Ok<bool>).value, isTrue);

      // First client again
      final rA2 = await a.repo.activateSession();
      expect(rA2, isA<Ok<bool>>());
      expect((rA2 as Ok<bool>).value, isFalse);

      await a.client.dispose();
      await b.client.dispose();
    });

    test('stranger account receives NotAllowedFailure', () async {
      final phone = await _repo(_stranger);
      final r = await phone.repo.activateSession();
      expect(r, isA<Err<bool>>());
      expect((r as Err<bool>).failure, isA<NotAllowedFailure>());
      await phone.client.dispose();
    });
  });
}
