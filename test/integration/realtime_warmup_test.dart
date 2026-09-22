@Tags(['warmup'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A readiness probe, not a test of the app.
///
/// After `supabase start` (or a reset) the Realtime service accepts a
/// subscription and reports `subscribed` well before its replication pipeline
/// actually delivers anything. The first integration suite to run then times
/// out waiting for a message that was published into a pipeline nobody was
/// reading yet — which looks exactly like a product bug and is not one.
///
/// This blocks until Realtime genuinely delivers once. It belongs in CI ahead
/// of the suites, the same way you wait for a database to accept connections
/// instead of sleeping and hoping. Raising the suites' timeouts would have
/// hidden a real regression later; this fails only if Realtime never becomes
/// ready at all.
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
  await client.rpc('activate_session');
  return client;
}

void main() {
  test('Realtime delivers a published insert', () async {
    final ann = await _signedIn('ann@integration.test');
    final bob = await _signedIn('bob@integration.test');
    addTearDown(() async {
      await ann.dispose();
      await bob.dispose();
    });

    final repo = SupabaseChatRepository(ann);
    final started = await repo.startDirectConversation(
      bob.auth.currentUser!.id,
    );
    final conversationId = (started as Ok<String>).value;

    final opened = await repo.incoming(conversationId);
    final stream = (opened as Ok<Stream<Message>>).value;
    final seen = <Message>[];
    final sub = stream.listen(seen.add);
    addTearDown(sub.cancel);

    // Publish repeatedly: the subscription can be live while the replication
    // pipeline behind it is not, and only a NEW insert exercises it.
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    var attempt = 0;
    while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
      attempt++;
      await repo.send(conversationId: conversationId, body: 'warmup $attempt');
      for (var i = 0; i < 20 && seen.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    expect(
      seen,
      isNotEmpty,
      reason: 'Realtime never delivered after $attempt attempts over 3 minutes',
    );
    // ignore: avoid_print
    print('Realtime ready after $attempt publish attempt(s)');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
