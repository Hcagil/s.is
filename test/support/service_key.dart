import 'dart:convert';
import 'dart:io';

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
