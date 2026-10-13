import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Password for integration-test accounts on the local test database only:
/// random, made once per test file (isolate), never written down. Accounts
/// left by earlier runs are moved to it by [setLocalTestPassword]. Every file
/// that signs in to an account another file moves must move it too: a file
/// with a fixed password is locked out (its sign-up then fails with 422).
final localTestPassword = base64Url.encode(
  List<int>.generate(24, (_) => Random.secure().nextInt(256)),
);

/// Sets [password] on the existing account [email] through Auth's admin API
/// at [url] (`GET /admin/users` to find it, `PUT /admin/users/<id>`). An account
/// that does not exist yet is left to the normal sign-up, so the allowlist
/// hook still decides who may join.
Future<void> setLocalTestPassword(
  String url,
  String email,
  String password,
) async {
  final http = HttpClient();
  final key = serviceKey();
  Future<(int, String)> call(String method, String path, [Object? body]) async {
    final request = await http.openUrl(method, Uri.parse('$url$path'));
    request.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key')
      ..contentType = ContentType.json;
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  }

  try {
    for (var page = 1; ; page++) {
      final (status, text) = await call(
        'GET',
        '/auth/v1/admin/users?page=$page&per_page=500',
      );
      if (status != 200) throw StateError('admin list users: $status $text');
      final users = (jsonDecode(text) as Map<String, dynamic>)['users'] as List;
      if (users.isEmpty) return; // not made yet: sign-up will create it
      for (final u in users.cast<Map<String, dynamic>>()) {
        if ((u['email'] as String?)?.toLowerCase() != email.toLowerCase()) {
          continue;
        }
        final (put, body) = await call(
          'PUT',
          '/auth/v1/admin/users/${u['id']}',
          {'password': password},
        );
        if (put != 200) throw StateError('admin set password: $put $body');
        return;
      }
    }
  } finally {
    http.close(force: true);
  }
}

/// The local test stack's service-role key, for the few fixtures only the
/// server may create (a dangling photo reference, a backdated message).
///
/// Read at run time, never written in the repository: CI passes it from
/// `supabase status -o env` (SECRET_KEY). Locally:
///   docker compose run --rm -e SUPABASE_TEST_SERVICE_KEY="$(docker compose \
///     run --rm supabase status -o env | sed -n 's/^SECRET_KEY="\(.*\)"/\1/p')" \
///     flutter flutter test --run-skipped --tags integration ...
String serviceKey() {
  final key = Platform.environment['SUPABASE_TEST_SERVICE_KEY'] ?? '';
  if (key.isEmpty) {
    throw StateError(
      'SUPABASE_TEST_SERVICE_KEY is not set: pass the local stack\'s '
      'SECRET_KEY (see test/support/service_key.dart).',
    );
  }
  return key;
}

/// Makes sure a confirmed [email] account with [password] exists, created
/// through Auth's admin API at [url]. The admin API does not run the sign-up
/// hook, so this is how a fixture gets a user who is deliberately NOT on the
/// allowlist (a public sign-up of one is refused with 403 "not invited").
Future<void> ensureUninvitedUser(
  String url,
  String email,
  String password,
) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(Uri.parse('$url/auth/v1/admin/users'));
    final key = serviceKey();
    request.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key')
      ..contentType = ContentType.json;
    request.write(
      jsonEncode({'email': email, 'password': password, 'email_confirm': true}),
    );
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    // 422 email_exists: made by an earlier run, which is all we need.
    if (response.statusCode != 200 && response.statusCode != 422) {
      throw StateError('admin create of $email: ${response.statusCode} $text');
    }
  } finally {
    http.close(force: true);
  }
}
