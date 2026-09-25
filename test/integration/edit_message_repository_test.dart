@Tags(['integration'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/service_key.dart';

/// [SupabaseChatRepository.editMessage] against the real local stack: the
/// real edit_message RPC, the row it returns, the UPDATE Realtime then
/// delivers -- to members only -- and every refusal arriving as a
/// DeniedFailure.
///
/// A fake cannot check any of that: a renamed RPC parameter, an edited_at
/// that is never parsed, or a subscription that ignores UPDATEs all pass
/// every unit test and fail on a phone.
///
/// Requires a running local Supabase, the warmup probe, and
/// SUPABASE_TEST_SERVICE_KEY (to backdate a message, which no client may).
/// Accounts edie/fitz/gale are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
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

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

void main() {
  SupabaseClient? edieClient;
  SupabaseClient? fitzClient;
  SupabaseClient? galeClient;
  SupabaseClient? service;
  late SupabaseChatRepository edie;
  late SupabaseChatRepository fitz;
  late SupabaseChatRepository gale;
  late String edieFitz;
  late String fitzGale;

  setUpAll(() async {
    edieClient = await _signedIn('edie@integration.test');
    fitzClient = await _signedIn('fitz@integration.test');
    galeClient = await _signedIn('gale@integration.test');
    service = _client(serviceKey());
    edie = SupabaseChatRepository(edieClient!);
    fitz = SupabaseChatRepository(fitzClient!);
    gale = SupabaseChatRepository(galeClient!);
    edieFitz = (await edie.startDirectConversation(
      fitzClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
    fitzGale = (await fitz.startDirectConversation(
      galeClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
  });

  tearDownAll(() async {
    for (final c in [edieClient, fitzClient, galeClient]) {
      await c?.removeAllChannels();
      await c?.dispose();
    }
    await service?.dispose();
  });

  Future<Message> sent(String body, {String? conversation}) async {
    final r = await edie.send(
      conversationId: conversation ?? edieFitz,
      body: body,
    );
    expect(r, isA<Ok<Message>>(), reason: 'send failed: $r');
    return (r as Ok<Message>).value;
  }

  /// The row as the other member reads it back from the database.
  Future<Message> stored(String id) async {
    final all = (await fitz.messages(edieFitz) as Ok<List<Message>>).value;
    return all.singleWhere((m) => m.id == id);
  }

  test(
    'an edit returns the updated row: new body, edit time, same message',
    () async {
      final original = await sent(_stamp('teh typo'));
      final body = _stamp('the typo');

      final result = await edie.editMessage(original, body);

      expect(result, isA<Ok<Message>>(), reason: 'edit refused: $result');
      final edited = (result as Ok<Message>).value;
      expect(edited.id, original.id);
      expect(edited.body, body);
      expect(edited.isEdited, isTrue);
      expect(
        edited.editedAt!.difference(DateTime.now()).inSeconds.abs(),
        lessThan(60),
        reason: 'edited_at is the server\'s now(), read as the same instant',
      );
      expect(edited.createdAt, original.createdAt);
      expect(edited.senderId, original.senderId);

      final reread = await stored(original.id);
      expect(reread.body, body, reason: 'the other member reads the new body');
      expect(
        reread.isEdited,
        isTrue,
        reason: 'a history read parses edited_at',
      );
    },
  );

  test(
    'Realtime delivers the edit to the other member, on both channels',
    () async {
      final original = await sent(_stamp('before'));
      final body = _stamp('after');

      final own = await fitz.incoming(edieFitz);
      final all = await fitz.incomingAll();
      expect(own, isA<Ok<Stream<Message>>>());
      expect(all, isA<Ok<Stream<Message>>>());
      final inChat = (own as Ok<Stream<Message>>).value
          .firstWhere((m) => m.id == original.id && m.body == body)
          .timeout(const Duration(seconds: 20));
      final inList = (all as Ok<Stream<Message>>).value
          .firstWhere((m) => m.id == original.id && m.body == body)
          .timeout(const Duration(seconds: 20));

      expect(await edie.editMessage(original, body), isA<Ok<Message>>());

      final a = await inChat;
      final b = await inList;
      expect(a.isEdited, isTrue, reason: 'the UPDATE carries edited_at');
      expect(b.isEdited, isTrue);
      expect(a.createdAt, original.createdAt);
      expect(a.isDeleted, isFalse);
    },
  );

  test('a non-member never receives the edit', () async {
    final original = await sent(_stamp('for fitz only'));
    final secret = _stamp('edited for fitz only');

    final opened = await gale.incomingAll();
    final received = <Message>[];
    final sub = (opened as Ok<Stream<Message>>).value.listen(received.add);
    addTearDown(sub.cancel);

    // Positive control: gale's subscription is live -- fitz writes to her.
    final control = _stamp('fitz to gale');
    await fitz.send(conversationId: fitzGale, body: control);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!received.any((m) => m.body == control)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('positive control: gale\'s subscription never delivered');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Fitz, a member, subscribed the same way: once his copy of the edit has
    // arrived, gale's would have too.
    final fitzAll = (await fitz.incomingAll() as Ok<Stream<Message>>).value;
    final fitzCopy = fitzAll
        .firstWhere((m) => m.id == original.id && m.body == secret)
        .timeout(const Duration(seconds: 20));

    expect(await edie.editMessage(original, secret), isA<Ok<Message>>());
    await fitzCopy;
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(received.map((m) => m.id), isNot(contains(original.id)));
    expect(received.map((m) => m.body), isNot(contains(secret)));
  });

  test('a photo\'s caption can be emptied; the photo stays', () async {
    final r = await edie.sendImage(
      conversationId: edieFitz,
      image: PickedImage(
        bytes: _png,
        contentType: 'image/png',
        extension: 'png',
      ),
      body: _stamp('caption'),
    );
    final photo = (r as Ok<Message>).value;

    final result = await edie.editMessage(photo, '');

    expect(result, isA<Ok<Message>>(), reason: 'edit refused: $result');
    final edited = (result as Ok<Message>).value;
    expect(edited.body.trim(), isEmpty);
    expect(edited.attachmentPath, photo.attachmentPath);
    expect(edited.isEdited, isTrue);
    expect((await stored(photo.id)).attachmentPath, photo.attachmentPath);
  });

  group('refusals arrive as DeniedFailure and change nothing', () {
    Future<void> unchanged(Message m) async {
      final now = await stored(m.id);
      expect(now.body, m.body);
      expect(now.isEdited, isFalse);
    }

    test('someone else\'s message', () async {
      final original = await sent(_stamp('edie wrote this'));
      final result = await fitz.editMessage(original, 'fitz rewrote it');
      expect(result, isA<Err<Message>>());
      expect((result as Err<Message>).failure, isA<DeniedFailure>());
      await unchanged(original);
    });

    test('a message over 6 hours old', () async {
      final original = await sent(_stamp('old news'));
      await service!
          .from('messages')
          .update({
            'created_at': DateTime.now()
                .toUtc()
                .subtract(const Duration(hours: 6, minutes: 1))
                .toIso8601String(),
          })
          .eq('id', original.id);
      final result = await edie.editMessage(original, 'too late');
      expect(result, isA<Err<Message>>());
      expect((result as Err<Message>).failure, isA<DeniedFailure>());
      await unchanged(original);
    });

    test('a deleted message', () async {
      final original = await sent(_stamp('regret'));
      expect(await edie.deleteForEveryone(original), isA<Ok<void>>());
      final result = await edie.editMessage(original, 'undo');
      expect(result, isA<Err<Message>>());
      expect((result as Err<Message>).failure, isA<DeniedFailure>());
    });

    test('a forwarded message', () async {
      final source = await sent(_stamp('pass it on'));
      expect(await edie.forward(source, [edieFitz]), isA<Ok<void>>());
      final rows = (await edie.messages(edieFitz) as Ok<List<Message>>).value;
      final copy = rows.lastWhere((m) => m.forwarded && m.body == source.body);
      final result = await edie.editMessage(copy, 'my words now');
      expect(result, isA<Err<Message>>());
      expect((result as Err<Message>).failure, isA<DeniedFailure>());
      await unchanged(copy);
    });

    test('an empty text message', () async {
      final original = await sent(_stamp('not empty'));
      final result = await edie.editMessage(original, '   ');
      expect(result, isA<Err<Message>>());
      await unchanged(original);
    });
  });
}
