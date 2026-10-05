@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/service_key.dart';

/// The sign-up gate against real Auth: the before-user-created hook
/// (app_private.before_user_created), on in supabase/config.toml as in
/// production. Contract:
///
/// - a public /auth/v1/signup of an uninvited address, or of the allowlisted
///   bot address sis-destek-bot@example.com (reserved domain), is refused with
///   403 {"code":403,"error_code":"unknown","msg":"not invited"} and creates
///   nothing;
/// - an invited address signs up;
/// - the admin API (POST /auth/v1/admin/users) does not run the hook, so it
///   can create the bot.
///
/// "Creates nothing" is read through Auth's admin API (auth.users with their
/// identities) and PostgREST (profiles). auth.sessions and
/// app_private.active_sessions cannot exist without an auth.users row (both
/// reference it; supabase/tests/signup_hook_test.sql pins those keys).
///
/// Requires the local stack and SUPABASE_TEST_SERVICE_KEY
/// (see test/support/service_key.dart).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'gate-test-password-1';
const _bot = 'sis-destek-bot@example.com';
const _invited = 'gate-invited@integration.test';
const _plus = 'gate-invited+x@integration.test';
const _notInvited = {
  'code': 403,
  'error_code': 'unknown',
  'msg': 'not invited',
};

/// One request; [admin] uses the service key. Returns (status, body, headers).
Future<(int, Object?, HttpHeaders)> _call(
  String method,
  String path, {
  Object? body,
  bool admin = false,
  Map<String, String> headers = const {},
}) async {
  final http = HttpClient();
  try {
    final request = await http.openUrl(method, Uri.parse('$_url$path'));
    final key = admin ? serviceKey() : _key;
    request.headers.set('apikey', key);
    if (admin) request.headers.set('Authorization', 'Bearer $key');
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = text;
    }
    return (response.statusCode, json, response.headers);
  } finally {
    http.close(force: true);
  }
}

Future<(int, Object?)> _signUp(String email) async {
  final (status, body, _) = await _call(
    'POST',
    '/auth/v1/signup',
    body: {'email': email, 'password': _password},
  );
  return (status, body);
}

/// Every auth user, through the admin API.
Future<List<Map<String, dynamic>>> _allUsers() async {
  final all = <Map<String, dynamic>>[];
  for (var page = 1; ; page++) {
    final (status, body, _) = await _call(
      'GET',
      '/auth/v1/admin/users?page=$page&per_page=1000',
      admin: true,
    );
    expect(status, 200, reason: 'admin listing failed: $body');
    final users = ((body! as Map<String, dynamic>)['users'] as List)
        .cast<Map<String, dynamic>>();
    if (users.isEmpty) return all;
    all.addAll(users);
  }
}

/// Users whose own email, or any identity's email, is [email].
Future<List<Map<String, dynamic>>> _usersWith(String email) async {
  final e = email.trim().toLowerCase();
  return [
    for (final u in await _allUsers())
      if ((u['email'] as String?)?.toLowerCase() == e ||
          ((u['identities'] as List?) ?? const []).any(
            (i) =>
                ((i as Map)['identity_data'] as Map?)?['email']
                    ?.toString()
                    .toLowerCase() ==
                e,
          ))
        u,
  ];
}

Future<int> _profileCount() async {
  final (status, body, headers) = await _call(
    'GET',
    '/rest/v1/profiles?select=user_id',
    admin: true,
    headers: {'Prefer': 'count=exact', 'Range': '0-0'},
  );
  expect(status, anyOf(200, 206), reason: 'profile count failed: $body');
  final range = headers.value('content-range')!;
  return int.parse(range.split('/').last);
}

Future<void> _deleteUsersWith(String email) async {
  for (final u in await _usersWith(email)) {
    final (status, body, _) = await _call(
      'DELETE',
      '/auth/v1/admin/users/${u['id']}',
      admin: true,
    );
    expect(status, 200, reason: 'cleanup of $email failed: $body');
  }
}

/// [email]'s public sign-up is refused with exactly the hook's 403, and
/// leaves no user, identity or profile behind.
Future<void> _expectRefused(String email) async {
  final users = (await _allUsers()).length;
  final profiles = await _profileCount();

  final (status, body) = await _signUp(email);

  expect(status, 403, reason: 'sign-up of "$email" was not refused: $body');
  expect(body, _notInvited);
  expect(await _usersWith(email), isEmpty, reason: 'a user was left behind');
  expect((await _allUsers()).length, users, reason: 'auth.users grew');
  expect(await _profileCount(), profiles, reason: 'profiles grew');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final stranger =
      'gate-stranger-${DateTime.now().microsecondsSinceEpoch}@integration.test';

  setUpAll(() async {
    // A run against a broken gate may have created any of these.
    for (final e in [_bot, _invited, _plus]) {
      await _deleteUsersWith(e);
    }
  });
  tearDownAll(() async {
    // A run against a broken gate may have created any of these.
    for (final e in [_bot, _invited, _plus]) {
      await _deleteUsersWith(e);
    }
  });

  group('public sign-up', () {
    test('an uninvited address is refused and leaves nothing', () async {
      await _expectRefused(stranger);
    });

    test('plus-addressing an invited address is refused', () async {
      await _expectRefused(_plus);
    });

    test('the bot address is refused although it is allowlisted', () async {
      await _expectRefused(_bot);
    });

    test('the bot address in mixed case is refused too', () async {
      await _expectRefused('SIS-Destek-Bot@Example.COM');
    });

    test('the SDK surfaces the refusal as AuthException 403 "not invited" '
        '(what SupabaseAuthRepository maps to DeniedFailure)', () async {
      final client = SupabaseClient(
        _url,
        _key,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
          autoRefreshToken: false,
        ),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.auth.signUp(email: stranger, password: _password),
        throwsA(
          isA<AuthException>()
              .having((e) => e.statusCode, 'statusCode', '403')
              .having((e) => e.message, 'message', 'not invited'),
        ),
      );
      expect(await _usersWith(stranger), isEmpty);
    });

    test('an invited address signs up', () async {
      final profiles = await _profileCount();
      final (status, body) = await _signUp(_invited);

      expect(status, 200, reason: 'invited sign-up refused: $body');
      final made = await _usersWith(_invited);
      expect(made, hasLength(1));
      expect(await _profileCount(), profiles + 1);
    });
  });

  group('admin create (no hook)', () {
    test('creates the bot address the public path refuses', () async {
      final (status, body, _) = await _call(
        'POST',
        '/auth/v1/admin/users',
        admin: true,
        body: {'email': _bot, 'password': _password, 'email_confirm': true},
      );

      expect(status, 200, reason: 'admin create refused: $body');
      expect((body! as Map)['email'], _bot);
      expect(await _usersWith(_bot), hasLength(1));
    });
  });
}
