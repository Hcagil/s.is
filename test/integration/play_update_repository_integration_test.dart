@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/update/data/play_update_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `PlayUpdateRepository.minSupportedBuild()` against a running local
/// Supabase.
///
/// Every other call on this repository wraps the Play in-app-update API,
/// which has nothing to run against locally (see docs/ARCHITECTURE.md) --
/// but `minSupportedBuild()` is query shaping over `app_config`, same as any
/// other repository that reads our own database, and a fake cannot check
/// that the column name and the singleton row id are the database's.
///
/// Requires `docker compose run --rm supabase start`. Reuses cleo
/// (supabase/seed.sql); run with --concurrency=1 like the rest of the suite.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A host that accepts nothing: the honest form of "the connection failed".
const _deadUrl = 'http://127.0.0.1:1';

SupabaseClient _client(String url) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> signedIn(String email) async {
  final client = _client(_url);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final clients = <SupabaseClient>[];
  tearDownAll(() async {
    for (final c in clients) {
      await c.dispose();
    }
  });

  test('minSupportedBuild() reads the real singleton row', () async {
    final client = await signedIn('cleo@integration.test');
    clients.add(client);

    final result = await PlayUpdateRepository(client).minSupportedBuild();

    expect(result, isA<Ok<int>>(), reason: '$result');
    expect((result as Ok<int>).value, greaterThanOrEqualTo(1));
  });

  test('a broken connection: minSupportedBuild() fails with the offline '
      'message, not raw SDK text', () async {
    final dead = _client(_deadUrl);
    clients.add(dead);

    final result = await PlayUpdateRepository(dead).minSupportedBuild();

    expect(result, isA<Err<int>>());
    final message = (result as Err<int>).failure.message;
    expect(message, offlineMessage);
    for (final needle in [
      'Exception',
      'statusCode',
      'errno',
      'Failed host lookup',
    ]) {
      expect(
        message,
        isNot(contains(needle)),
        reason: 'raw error text reached the screen: $message',
      );
    }
  });
}
