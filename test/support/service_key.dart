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
