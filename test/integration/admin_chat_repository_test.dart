@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_admin_chat_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [SupabaseAdminChatRepository.answer] against the real local stack: the
/// real admin_answer RPC refuses a member who is not the owner with 42501,
/// which must reach the app as DeniedFailure. A renamed RPC or parameter
/// answers with a different error and turns this red.
///
/// The owner's own path needs an app_private.owners row, which no client can
/// write; supabase/tests/admin_chat_test.sql covers it at the database.
/// Accounts edie is this suite family's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _seedPw = 'integration-password';

void main() {
  late SupabaseClient client;

  setUpAll(() async {
    client = SupabaseClient(
      _url,
      _key,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    try {
      await client.auth.signInWithPassword(
        email: 'edie@integration.test',
        password: _seedPw,
      );
    } on AuthException {
      await client.auth.signUp(
        email: 'edie@integration.test',
        password: _seedPw,
      );
    }
    expect(await client.rpc('activate_session'), isTrue);
  });

  tearDownAll(() => client.dispose());

  for (final yes in [true, false]) {
    test(
      'a member who is not the owner: answer($yes) is DeniedFailure',
      () async {
        final r = await SupabaseAdminChatRepository(client)
            .answer('00000000-0000-0000-0000-0000000ac0fe', yes);
        expect(r, isA<Err<void>>());
        expect((r as Err<void>).failure, isA<DeniedFailure>());
      },
    );
  }
}
