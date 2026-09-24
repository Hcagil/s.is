@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Regression: an insert event that carries no row must not reach
/// `_toMessage`'s casts, and must not disturb the stream for anything that
/// arrives after it.
///
/// Reproduces the CI flake in account_switch_integration_test.dart: a channel
/// left open past its account's sign-out can still receive a postgres_changes
/// insert event whose `record` the server withheld because it could not
/// authorise it. `SupabaseChatRepository._toMessage` casts `row['id']` to
/// `String`; a `null` there throws inside the Realtime client's own callback,
/// which used to escape uncaught.
///
/// Drives the repository's own channel (obtained via `getChannels()` after
/// `incoming()` resolves) with `RealtimeChannel.trigger`, shaped exactly as
/// `getEnrichedPayload` in package:realtime_client expects: a top-level
/// postgres-changes frame with an empty `record` and no `columns`, which
/// `PostgresChangePayload.fromPayload` turns into an empty `newRecord` map --
/// the same shape an authorisation-refused insert produces on the wire.
///
/// Requires `docker compose run --rm supabase start`. Reuses ann/bob
/// (supabase/seed.sql) the same way realtime_warmup_test.dart already shares
/// them with chat_repository_test.dart: a fresh direct conversation is
/// created per run, so nothing here depends on state left by another suite.
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

/// A synthetic Realtime frame for an insert the server could not authorise:
/// no columns, no record, same as a genuine authorization-error event.
Map<String, dynamic> _rowlessInsertFrame() => {
  'type': 'INSERT',
  'schema': 'public',
  'table': 'messages',
  'commit_timestamp': DateTime.now().toUtc().toIso8601String(),
  'columns': <Map<String, dynamic>>[],
  'record': <String, dynamic>{},
  'old_record': <String, dynamic>{},
  'errors': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? annClient;
  SupabaseClient? bobClient;

  setUpAll(() async {
    bobClient = await _signedIn('bob@integration.test');
    annClient = await _signedIn('ann@integration.test');
  });

  tearDownAll(() async {
    await annClient?.dispose();
    await bobClient?.dispose();
  });

  test('a row-less insert event is ignored, and a later real insert still '
      'arrives on the same stream', () async {
    final ann = SupabaseChatRepository(annClient!);
    final bob = SupabaseChatRepository(bobClient!);

    final started = await ann.startDirectConversation(
      bobClient!.auth.currentUser!.id,
    );
    final conversationId = (started as Ok<String>).value;

    final opened = await bob.incoming(conversationId);
    expect(opened, isA<Ok<Stream<Message>>>(), reason: 'subscription refused');
    final stream = (opened as Ok<Stream<Message>>).value;

    final events = <Message>[];
    Object? streamError;
    final sub = stream.listen(
      events.add,
      onError: (Object e) => streamError = e,
    );
    addTearDown(sub.cancel);

    // The repository's own channel for this conversation: `incoming`
    // resolved, so the join already completed and the binding is live.
    final channel = bobClient!.getChannels().singleWhere(
      // The SDK marks this internal, but it is the only public way to tell
      // the repository's channels apart by the conversation they serve.
      // ignore: invalid_use_of_internal_member
      (c) => c.topic == 'realtime:messages:$conversationId',
      orElse: () => fail(
        'the repository did not leave a channel for this conversation '
        'behind -- getChannels() cannot find what incoming() joined',
      ),
    );

    // Drive the exact defect: an insert callback fires with a record the
    // server withheld. Without the guard this throws inside the Realtime
    // client's own dispatch, uncaught.
    channel.trigger('insert', _rowlessInsertFrame());

    // trigger() invokes the callback synchronously, but the controller
    // delivers to the listener on a later microtask/event-loop turn.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      streamError,
      isNull,
      reason: 'a row-less insert must not error the message stream',
    );
    expect(
      events,
      isEmpty,
      reason: 'a row-less insert must not emit a message',
    );

    // The same stream must still be good for a real insert afterwards.
    // Sent repeatedly, the way realtime_warmup_test.dart does: a
    // subscription can report joined while the replication pipeline behind
    // it is not yet delivering, and only a fresh insert exercises it.
    final seenBodies = <String>{};
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    var attempt = 0;
    while (seenBodies.intersection(events.map((m) => m.body).toSet()).isEmpty &&
        DateTime.now().isBefore(deadline)) {
      attempt++;
      final body =
          'after-rowless-insert $attempt '
          '${DateTime.now().microsecondsSinceEpoch}';
      seenBodies.add(body);
      expect(
        await ann.send(conversationId: conversationId, body: body),
        isA<Ok>(),
      );
      for (var i = 0; i < 20 && events.every((m) => m.body != body); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    expect(
      events.map((m) => m.body).toSet().intersection(seenBodies),
      isNotEmpty,
      reason:
          'a later real insert must still be delivered after '
          '$attempt attempt(s)',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}
