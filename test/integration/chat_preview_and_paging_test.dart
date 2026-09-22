@Tags(['integration'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Two behaviours of [SupabaseChatRepository] that only the real stack can
/// show: what the conversation list previews, and what a conversation longer
/// than the read limit returns.
///
/// Neither is reachable with a fake. The preview string is produced while
/// shaping the PostgREST response, and the truncation it guards against is
/// PostgREST's own `max_rows` — a fake repository would answer with whatever
/// list the test handed it and agree with any implementation.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts (supabase/seed.sql): signing in claims the active device, so
/// sharing a pair with another suite would evict it.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real 1x1 PNG: the bucket checks the mime type, so fake bytes are refused
/// before they can produce an attachment to preview.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage _image() =>
    PickedImage(bytes: _png, contentType: 'image/png', extension: 'png');

/// How many messages the long conversation gets, and in how many writes.
///
/// The count only has to exceed the limit the repository reads with, which is
/// private and deliberately not asserted here. The batching is what makes the
/// result decidable: `created_at` defaults to `now()`, which is the
/// transaction timestamp, so one insert of every row would stamp them all
/// identically and "the oldest are the ones missing" would mean nothing. One
/// insert per batch gives each batch a strictly later timestamp than the last,
/// and the assertions below only ever speak about whole batches.
const _batchSize = 40;
const _batchCount = 14; // 560 rows: comfortably past the limit under test.
const _totalMessages = _batchSize * _batchCount;

/// Newer messages piled into ONE other conversation, to show that a preview
/// does not come out of a window shared with every other conversation. 260
/// because the window that used to exist held 200; the point is that no such
/// window remains, so any number past it will do.
const _busierThanAnyWindow = 260;

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

void main() {
  SupabaseClient? oliveClient;
  SupabaseClient? peteClient;
  SupabaseClient? quinnClient;
  late SupabaseChatRepository olive;

  /// olive <-> pete: every preview assertion writes its own newest message
  /// here.
  late String previewConversation;

  /// olive <-> quinn: started and never written to.
  late String silentConversation;

  /// A group, because it is the one call that always creates a fresh
  /// conversation — a long thread must not land on top of the previews.
  late String longConversation;

  /// Bodies of the batch written first and the batch written last.
  late List<String> oldestBatch;
  late List<String> newestBatch;

  Future<List<Message>> messagesIn(String conversationId) async {
    final result = await olive.messages(conversationId);
    expect(result, isA<Ok<List<Message>>>(), reason: 'the read failed');
    return (result as Ok<List<Message>>).value;
  }

  Future<Conversation> conversationRow(String id) async {
    final result = await olive.conversations();
    expect(result, isA<Ok<List<Conversation>>>());
    return (result as Ok<List<Conversation>>).value.firstWhere(
      (c) => c.id == id,
      orElse: () => fail('conversation $id is missing from the list'),
    );
  }

  setUpAll(() async {
    quinnClient = await _signedIn('quinn@integration.test');
    peteClient = await _signedIn('pete@integration.test');
    oliveClient = await _signedIn('olive@integration.test');
    olive = SupabaseChatRepository(oliveClient!);

    final withPete = await olive.startDirectConversation(
      peteClient!.auth.currentUser!.id,
    );
    expect(withPete, isA<Ok<String>>());
    previewConversation = (withPete as Ok<String>).value;

    final withQuinn = await olive.startDirectConversation(
      quinnClient!.auth.currentUser!.id,
    );
    expect(withQuinn, isA<Ok<String>>());
    silentConversation = (withQuinn as Ok<String>).value;

    final group = await olive.startGroupConversation(
      title: 'long thread ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [peteClient!.auth.currentUser!.id],
    );
    expect(group, isA<Ok<String>>());
    longConversation = (group as Ok<String>).value;

    // Written straight through PostgREST rather than through send(): 560 round
    // trips would dominate the suite, and the subject here is the read.
    final senderId = oliveClient!.auth.currentUser!.id;
    final nonce = DateTime.now().microsecondsSinceEpoch;
    for (var batch = 0; batch < _batchCount; batch++) {
      final bodies = [
        for (var i = 0; i < _batchSize; i++) 'bulk-$nonce-b$batch-i$i',
      ];
      await oliveClient!.from('messages').insert([
        for (final body in bodies)
          {
            'conversation_id': longConversation,
            'sender_id': senderId,
            'body': body,
          },
      ]);
      if (batch == 0) oldestBatch = bodies;
      if (batch == _batchCount - 1) newestBatch = bodies;
    }
  });

  tearDownAll(() async {
    await oliveClient?.dispose();
    await peteClient?.dispose();
    await quinnClient?.dispose();
  });

  group('the conversation list preview', () {
    test('a conversation with no messages at all has no preview', () async {
      final row = await conversationRow(silentConversation);
      expect(
        row.lastMessage,
        isNull,
        reason: 'null is reserved for "nothing has been sent"',
      );
      expect(row.lastMessageAt, isNull);
    });

    test('a text message previews as its body', () async {
      final body = 'text ${DateTime.now().microsecondsSinceEpoch}';
      expect(
        await olive.send(conversationId: previewConversation, body: body),
        isA<Ok<Message>>(),
      );

      final row = await conversationRow(previewConversation);
      expect(row.lastMessage, body);
      expect(row.lastMessageAt, isNotNull);
    });

    test('an image with no caption previews as Photo', () async {
      // The bug this covers: the photo arrived last, previewed as an empty
      // string, and the text below it was shown as the newest message.
      final older = 'older text ${DateTime.now().microsecondsSinceEpoch}';
      expect(
        await olive.send(conversationId: previewConversation, body: older),
        isA<Ok<Message>>(),
      );

      final sent = await olive.sendImage(
        conversationId: previewConversation,
        image: _image(),
      );
      expect(sent, isA<Ok<Message>>(), reason: 'the real upload was refused');
      expect(
        (sent as Ok<Message>).value.body,
        isEmpty,
        reason: 'this is the image-only case; a caption would preview instead',
      );

      final row = await conversationRow(previewConversation);
      expect(
        row.lastMessage,
        'Photo',
        reason: 'an image-only message must preview as something readable',
      );
      expect(
        row.lastMessage,
        isNot(older),
        reason: 'the older text must not outrank the newest message',
      );
    });

    test('a captioned image previews as its caption, not as Photo', () async {
      final caption = 'caption ${DateTime.now().microsecondsSinceEpoch}';
      expect(
        await olive.sendImage(
          conversationId: previewConversation,
          image: _image(),
          body: caption,
        ),
        isA<Ok<Message>>(),
      );

      expect((await conversationRow(previewConversation)).lastMessage, caption);
    });

    test('a text message sent after a photo takes the preview back', () async {
      expect(
        await olive.sendImage(
          conversationId: previewConversation,
          image: _image(),
        ),
        isA<Ok<Message>>(),
      );
      final newer = 'newer ${DateTime.now().microsecondsSinceEpoch}';
      expect(
        await olive.send(conversationId: previewConversation, body: newer),
        isA<Ok<Message>>(),
      );

      expect(
        (await conversationRow(previewConversation)).lastMessage,
        newer,
        reason: 'the preview is the newest message, whatever kind it is',
      );
    });

    test('survives another conversation being far busier', () async {
      // A preview must depend on the conversation it belongs to and nothing
      // else. Reading one bounded window of the member's newest messages
      // across every conversation cannot do that: a busy group crosses any
      // fixed window in ordinary use, and every quieter conversation then
      // renders "No messages yet" while plainly having messages.
      final quiet = 'quiet ${DateTime.now().microsecondsSinceEpoch}';
      expect(
        await olive.send(conversationId: previewConversation, body: quiet),
        isA<Ok<Message>>(),
      );

      final busy = await olive.startGroupConversation(
        title: 'busy ${DateTime.now().microsecondsSinceEpoch}',
        memberIds: [peteClient!.auth.currentUser!.id],
      );
      expect(busy, isA<Ok<String>>());
      final busyId = (busy as Ok<String>).value;
      final senderId = oliveClient!.auth.currentUser!.id;
      await oliveClient!.from('messages').insert([
        for (var i = 0; i < _busierThanAnyWindow; i++)
          {
            'conversation_id': busyId,
            'sender_id': senderId,
            'body': 'busy-${DateTime.now().microsecondsSinceEpoch}-$i',
          },
      ]);

      expect(
        (await conversationRow(previewConversation)).lastMessage,
        quiet,
        reason:
            'the quiet conversation has a message, so its preview must be that '
            'message and never null, however many newer messages exist '
            'elsewhere',
      );
      expect(
        (await conversationRow(busyId)).lastMessage,
        isNotNull,
        reason: 'the busy conversation must keep a preview of its own too',
      );
    });
  });

  group('a conversation longer than the read limit', () {
    test('is returned oldest first', () async {
      final loaded = await messagesIn(longConversation);
      for (var i = 1; i < loaded.length; i++) {
        expect(
          loaded[i].createdAt.isBefore(loaded[i - 1].createdAt),
          isFalse,
          reason:
              'message $i (${loaded[i].createdAt}) precedes its predecessor '
              '(${loaded[i - 1].createdAt}): the list is not oldest first',
        );
      }
      expect(
        loaded.first.createdAt.isBefore(loaded.last.createdAt),
        isTrue,
        reason: 'the first element must be the oldest one returned',
      );
    });

    test('is truncated, and it is the OLD messages that are missing', () async {
      final bodies = (await messagesIn(longConversation))
          .map((m) => m.body)
          .toSet();

      expect(
        bodies.length,
        lessThan(_totalMessages),
        reason:
            'a $_totalMessages message conversation came back whole: either '
            'the read is unbounded, or the limit is above what this test '
            'writes',
      );
      expect(
        bodies.intersection(newestBatch.toSet()),
        hasLength(newestBatch.length),
        reason: 'the most recent messages must always be the ones kept',
      );
      expect(
        bodies.intersection(oldestBatch.toSet()),
        isEmpty,
        reason:
            'the oldest batch survived while the conversation was truncated, '
            'so the newest messages were the ones dropped',
      );
    });

    test('still shows a message sent now, at the end of the list', () async {
      final body = 'after the cap ${DateTime.now().microsecondsSinceEpoch}';
      expect(
        await olive.send(conversationId: longConversation, body: body),
        isA<Ok<Message>>(),
      );

      final loaded = await messagesIn(longConversation);
      expect(
        loaded.last.body,
        body,
        reason:
            'a long conversation must not freeze in the past: the message just '
            'sent belongs at the bottom of the screen',
      );
    });
  });
}
