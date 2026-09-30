@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/service_key.dart';

/// The fixed system account (the What's new sender) against real GoTrue.
///
/// The migration writes that row straight into auth.users, so GoTrue never
/// created it. GoTrue scans several columns into non-nullable Go types; a NULL
/// (a token column, created_at/updated_at) or a value it cannot parse
/// (banned_until 'infinity') makes every admin endpoint that reads the row
/// return 500 -- including the dashboard's Users page. Contract:
///
///   id 00000000-0000-0000-0000-00000000515e; no email, phone, password or
///   identity; banned until 2999-12-31; readable by GoTrue's admin API;
///   impossible to sign in as.
///
/// Requires `docker compose run --rm supabase start` and
/// SUPABASE_TEST_SERVICE_KEY (see test/support/service_key.dart).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _systemId = '00000000-0000-0000-0000-00000000515e';

/// GET an admin endpoint with the service key; returns (status, body).
Future<(int, Object?)> _admin(String path) async {
  final http = HttpClient();
  try {
    final request = await http.getUrl(Uri.parse('$_url/auth/v1/admin/$path'));
    final key = serviceKey();
    request.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? body;
    try {
      body = jsonDecode(text);
    } on FormatException {
      body = text;
    }
    return (response.statusCode, body);
  } finally {
    http.close(force: true);
  }
}

List<Map<String, dynamic>> _users(Object? body) =>
    ((body! as Map<String, dynamic>)['users'] as List)
        .cast<Map<String, dynamic>>();

void main() {
  test('one admin page large enough to hold every user lists them, '
      'the system account included', () async {
    final (status, body) = await _admin('users?page=1&per_page=1000');
    expect(status, 200, reason: 'admin user listing failed: $body');
    expect(_users(body).map((u) => u['id']), contains(_systemId));
  });

  test('paging through every user in small pages succeeds on every page '
      'and meets the system account exactly once', () async {
    final seen = <String>[];
    for (var page = 1; ; page++) {
      final (status, body) = await _admin('users?page=$page&per_page=7');
      expect(status, 200, reason: 'page $page failed: $body');
      final users = _users(body);
      if (users.isEmpty) break;
      seen.addAll(users.map((u) => u['id'] as String));
      expect(page, lessThan(10000), reason: 'paging never ends');
    }
    expect(seen.where((id) => id == _systemId), hasLength(1));
  });

  test('fetching the system account by id: no email, phone or identity, '
      'banned far into the future', () async {
    final (status, body) = await _admin('users/$_systemId');
    expect(status, 200, reason: 'admin get-user failed: $body');
    final user = body! as Map<String, dynamic>;
    expect(user['id'], _systemId);
    expect(user['email'] ?? '', isEmpty);
    expect(user['phone'] ?? '', isEmpty);
    expect((user['identities'] as List?) ?? const [], isEmpty);
    final banned = DateTime.parse(user['banned_until'] as String);
    expect(
      banned.isAfter(DateTime.utc(2999)),
      isTrue,
      reason: 'banned_until $banned',
    );
    expect(user['created_at'], isNotNull);
    expect(user['updated_at'], isNotNull);
  });

  group('nobody can sign in as the system account', () {
    // It has no email, phone, password or identity, so there is nothing to
    // present; every grant that could name it is refused.
    late SupabaseClient client;
    setUp(
      () => client = SupabaseClient(
        _url,
        _key,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      ),
    );
    tearDown(() => client.dispose());

    test('password grant with an empty email is refused', () async {
      await expectLater(
        client.auth.signInWithPassword(email: '', password: ''),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser, isNull);
    });

    test('password grant with an empty phone is refused', () async {
      await expectLater(
        client.auth.signInWithPassword(phone: '', password: ''),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser, isNull);
    });

    test('an email OTP to an empty address is refused', () async {
      await expectLater(
        client.auth.signInWithOtp(email: '', shouldCreateUser: false),
        throwsA(isA<AuthException>()),
      );
    });

    test('a phone OTP to an empty number is refused', () async {
      await expectLater(
        client.auth.signInWithOtp(phone: '', shouldCreateUser: false),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
