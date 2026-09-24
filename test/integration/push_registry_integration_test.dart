@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/notifications/data/supabase_push_registry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [SupabasePushRegistry] against the real stack: the register_device_token
/// and forget_device_token RPCs, over a signed-in client.
///
/// The unit tests for the push controller prove it calls a [PushRegistry] the
/// right way over a fake. Only this suite proves the RPC names and parameters
/// are the database's, that a signed-in allowlisted member is actually let
/// through, and that a caller who cannot possibly be allowed -- a plain
/// anonymous client, never signed in -- gets a readable [DeniedFailure]
/// rather than a thrown PostgrestException reaching a screen.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// account (supabase/seed.sql): iris. The refused path needs no seeded
/// account -- device_tokens is granted to `authenticated` only, so an anon
/// client is refused before any allowlist check runs.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

/// A token long enough to pass the table's own length check, and unique per
/// test run so two runs against the same database never collide on the
/// (user_id, token) primary key.
String _token() =>
    'itest-token-${DateTime.now().microsecondsSinceEpoch}'.padRight(12, '0');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient irisClient;
  final extra = <SupabaseClient>[];

  setUpAll(() async {
    irisClient = await _signedIn('iris@integration.test');
  });

  tearDown(() async {
    for (final c in extra) {
      await c.dispose();
    }
    extra.clear();
  });

  tearDownAll(() async {
    await irisClient.dispose();
  });

  group('a signed-in allowlisted member', () {
    test('registers a token, then forgets it', () async {
      final registry = SupabasePushRegistry(irisClient);
      final token = _token();

      final registered = await registry.register(token);
      expect(registered, isA<Ok<void>>(), reason: '$registered');

      final forgotten = await registry.forget(token);
      expect(forgotten, isA<Ok<void>>(), reason: '$forgotten');
    });

    test('registering the same token twice still succeeds (on-conflict '
        'update, not a duplicate-key failure)', () async {
      final registry = SupabasePushRegistry(irisClient);
      final token = _token();

      expect(await registry.register(token), isA<Ok<void>>());
      final again = await registry.register(token);
      expect(again, isA<Ok<void>>(), reason: '$again');

      await registry.forget(token);
    });

    test('forgetting a token that was never registered is still Ok -- best '
        'effort, not a failure', () async {
      final registry = SupabasePushRegistry(irisClient);
      final forgotten = await registry.forget(_token());
      expect(forgotten, isA<Ok<void>>(), reason: '$forgotten');
    });

    test('a token the check constraint refuses comes back as a readable '
        'failure, not DeniedFailure -- the "anything else" branch of the '
        'contract', () async {
      final registry = SupabasePushRegistry(irisClient);
      final result = await registry.register('short');
      expect(
        result,
        isA<Err<void>>(),
        reason: 'a 9-character token should fail the length check',
      );
      final failure = (result as Err<void>).failure;
      expect(
        failure,
        isNot(isA<DeniedFailure>()),
        reason: 'an invalid token is not an RLS refusal',
      );
      expect(failure.message, isNot(contains('PostgrestException')));
    });
  });

  group('a client that was never signed in', () {
    test('register is refused with DeniedFailure, never a throw', () async {
      final anon = _client();
      extra.add(anon);
      final result = await SupabasePushRegistry(anon).register(_token());
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
    });

    test('forget is refused with DeniedFailure, never a throw', () async {
      final anon = _client();
      extra.add(anon);
      final result = await SupabasePushRegistry(anon).forget(_token());
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
    });
  });

  group('offline', () {
    test(
      'a dead host reads as the offline message, not raw SDK text',
      () async {
        // A host that accepts nothing: the honest form of "the connection
        // failed", exactly as the other data-layer integration suites use it.
        final dead = SupabaseClient(
          'http://127.0.0.1:1',
          _key,
          authOptions: const AuthClientOptions(
            authFlowType: AuthFlowType.implicit,
          ),
        );
        extra.add(dead);
        final result = await SupabasePushRegistry(dead).register(_token());
        expect(result, isA<Err<void>>());
        final message = (result as Err<void>).failure.message;
        expect(message, offlineMessage);
        expect(message, isNot(contains('SocketException')));
      },
    );
  });
}
