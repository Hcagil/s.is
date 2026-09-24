@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A real 1x1 PNG: the bucket checks the mime type against real bytes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Exercises [SupabaseChatRepository]'s reply and forward against the real
/// local stack: real PostgREST queries, real storage copies, real RLS.
///
/// Requires `docker compose run --rm supabase start`. Uses reid, beth and
/// cora (supabase/seed.sql; password sign-in exists only locally).
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

void main() {
  SupabaseClient? annClient;
  SupabaseClient? bobClient;
  SupabaseClient? carlClient;
  late SupabaseChatRepository ann;
  late SupabaseChatRepository bob;
  late SupabaseChatRepository carl;
  // c1: ann+bob (the "source" conversation for forwards below).
  // c2: ann+carl (a forward target bob is not in).
  // c3: a group of all three -- forward's SECOND target.
  // bc: bob+carl (a conversation ann is not in at all).
  late String c1;
  late String c2;
  late String c3;
  late String bc;

  setUpAll(() async {
    bobClient = await _signedIn('beth@integration.test');
    annClient = await _signedIn('reid@integration.test');
    carlClient = await _signedIn('cora@integration.test');
    ann = SupabaseChatRepository(annClient!);
    bob = SupabaseChatRepository(bobClient!);
    carl = SupabaseChatRepository(carlClient!);

    final s1 = await ann.startDirectConversation(
      bobClient!.auth.currentUser!.id,
    );
    c1 = (s1 as Ok<String>).value;
    final s2 = await ann.startDirectConversation(
      carlClient!.auth.currentUser!.id,
    );
    c2 = (s2 as Ok<String>).value;
    final s3 = await bob.startDirectConversation(
      carlClient!.auth.currentUser!.id,
    );
    bc = (s3 as Ok<String>).value;
    final s4 = await ann.startGroupConversation(
      title: 'RF Group ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [
        bobClient!.auth.currentUser!.id,
        carlClient!.auth.currentUser!.id,
      ],
    );
    c3 = (s4 as Ok<String>).value;
  });

  tearDownAll(() async {
    await annClient?.dispose();
    await bobClient?.dispose();
    await carlClient?.dispose();
  });

  group('reply', () {
    test('replyTo is stored and read back as Message.replyTo', () async {
      final quoted = await ann.send(
        conversationId: c1,
        body: 'quoted ${DateTime.now().microsecondsSinceEpoch}',
      );
      final quotedId = (quoted as Ok<Message>).value.id;

      final reply = await bob.send(
        conversationId: c1,
        body: 'replying ${DateTime.now().microsecondsSinceEpoch}',
        replyTo: quotedId,
      );
      expect(reply, isA<Ok<Message>>());
      expect((reply as Ok<Message>).value.replyTo, quotedId);

      final loaded = (await ann.messages(c1) as Ok<List<Message>>).value
          .firstWhere((m) => m.id == (reply).value.id);
      expect(loaded.replyTo, quotedId);
    });

    test(
      'a reply naming a message of another conversation is refused',
      () async {
        final elsewhere = await ann.send(
          conversationId: c2,
          body: 'lives in c2 ${DateTime.now().microsecondsSinceEpoch}',
        );
        final elsewhereId = (elsewhere as Ok<Message>).value.id;

        final refused = await ann.send(
          conversationId: c1,
          body: 'should not land',
          replyTo: elsewhereId,
        );
        expect(refused, isA<Err<Message>>());
      },
    );
  });

  group('forward', () {
    test('a text message forwarded to two conversations creates two forwarded '
        'copies with the same body', () async {
      final body = 'fwd me ${DateTime.now().microsecondsSinceEpoch}';
      final original = await ann.send(conversationId: c1, body: body);
      final message = (original as Ok<Message>).value;

      final result = await ann.forward(message, [c2, c3]);
      expect(result, isA<Ok<void>>());

      final inC2 = (await carl.messages(c2) as Ok<List<Message>>).value
          .where((m) => m.body == body)
          .toList();
      final inC3 = (await bob.messages(c3) as Ok<List<Message>>).value
          .where((m) => m.body == body)
          .toList();
      expect(inC2, hasLength(1), reason: 'a forwarded copy landed in c2');
      expect(inC3, hasLength(1), reason: 'a forwarded copy landed in c3');
      for (final m in [...inC2, ...inC3]) {
        expect(m.forwarded, isTrue);
        expect(m.senderId, annClient!.auth.currentUser!.id);
      }
    });

    test(
      'a photo is copied into the target\'s own folder: readable there, the '
      'source untouched, and NOT readable by a member only of the source',
      () async {
        final sent = await ann.sendImage(
          conversationId: c1,
          image: PickedImage(
            bytes: _png,
            contentType: 'image/png',
            extension: 'png',
          ),
        );
        final original = (sent as Ok<Message>).value;
        final sourcePath = original.attachmentPath!;

        final result = await ann.forward(original, [c2]);
        expect(result, isA<Ok<void>>());

        final copy = (await carl.messages(c2) as Ok<List<Message>>).value
            .firstWhere((m) => m.forwarded && m.attachmentPath != null);
        final copyPath = copy.attachmentPath!;

        expect(
          copyPath,
          isNot(sourcePath),
          reason: 'the copy lives at a new path, never the source\'s own',
        );
        expect(
          copyPath.startsWith('$c2/'),
          isTrue,
          reason: 'the copy is filed in the TARGET\'s own folder',
        );

        // Readable by carl, a member of the target conversation.
        final byCarl = await carl.attachmentBytes(copyPath);
        expect(byCarl, isA<Ok<Uint8List>>());

        // NOT readable by bob, a member only of the source conversation.
        final byBob = await bob.attachmentBytes(copyPath);
        expect(byBob, isA<Err<Uint8List>>());

        // The original is untouched: still there, still bob's to read.
        final originalStillThere = await bob.attachmentBytes(sourcePath);
        expect(originalStillThere, isA<Ok<Uint8List>>());
      },
    );

    test('forwarding into a conversation the forwarder is not in fails '
        'with a readable failure', () async {
      final sent = await ann.send(
        conversationId: c1,
        body: 'trying to reach bc ${DateTime.now().microsecondsSinceEpoch}',
      );
      final message = (sent as Ok<Message>).value;

      final result = await ann.forward(message, [bc]);
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure.message, isNotEmpty);
    });
  });
}
