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

/// An [AttachmentCache] kept in memory, so a test can prove
/// [SupabaseChatRepository.deleteForEveryone] forgets a photo it holds.
class _MemoryCache implements AttachmentCache {
  final _store = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String path) async => _store[path];

  @override
  Future<void> write(String path, Uint8List bytes) async {
    _store[path] = bytes;
  }

  @override
  Future<void> remove(String path) async => _store.remove(path);

  @override
  Future<void> clear() async => _store.clear();
}

/// Exercises [SupabaseChatRepository] against the real local stack: real
/// PostgREST queries, real RPC, real Realtime, real row-level security.
///
/// This is the layer unit tests cannot reach. A wrong column name, a renamed
/// RPC parameter or a bad cast fails here instead of on a device.
///
/// Requires `docker compose run --rm supabase start`. Emails come from
/// supabase/seed.sql; password sign-in exists only locally.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// Signs [email] in (creating the account the first time) and claims the
/// active session, so `has_app_access()` is true for this client.
/// Headless: there is no secure storage to hold a PKCE verifier, and the
/// implicit flow does not need one.
SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> signedIn(String email, {bool activate = true}) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  if (activate) {
    expect(
      await client.rpc('activate_session'),
      isTrue,
      reason: 'activate_session refused an allowlisted user',
    );
  }
  return client;
}

void main() {
  SupabaseClient? annClient;
  SupabaseClient? bobClient;
  late SupabaseChatRepository ann;
  late SupabaseChatRepository bob;
  late String conversationId;

  setUpAll(() async {
    // Bob first: Ann activates last, but they are different users, so both
    // hold an active session at once.
    bobClient = await signedIn('bob@integration.test');
    annClient = await signedIn('ann@integration.test');
    ann = SupabaseChatRepository(annClient!);
    bob = SupabaseChatRepository(bobClient!);

    final started = await ann.startDirectConversation(
      bobClient!.auth.currentUser!.id,
    );
    expect(started, isA<Ok<String>>(), reason: 'the RPC signature must match');
    conversationId = (started as Ok<String>).value;
  });

  tearDownAll(() async {
    // Guarded: a failed setUpAll must not bury its own error under a
    // LateInitializationError from here.
    await annClient?.dispose();
    await bobClient?.dispose();
  });

  test('starting the same conversation twice returns the same id', () async {
    final again = await ann.startDirectConversation(
      bobClient!.auth.currentUser!.id,
    );
    expect((again as Ok<String>).value, conversationId);
  });

  test('a sent message is readable by both members', () async {
    final body = 'integration ${DateTime.now().microsecondsSinceEpoch}';
    expect(
      await ann.send(conversationId: conversationId, body: body),
      isA<Ok>(),
    );

    final mine = await ann.messages(conversationId);
    expect(
      (mine as Ok<List<Message>>).value.map((m) => m.body),
      contains(body),
    );

    final theirs = await bob.messages(conversationId);
    expect(
      (theirs as Ok<List<Message>>).value.map((m) => m.body),
      contains(body),
      reason: 'the other member must read it',
    );
  });

  test('messages parse into the domain model', () async {
    final body = 'parse ${DateTime.now().microsecondsSinceEpoch}';
    await ann.send(conversationId: conversationId, body: body);
    final loaded = (await ann.messages(conversationId) as Ok<List<Message>>)
        .value
        .firstWhere((m) => m.body == body);

    // Every column the repository names must exist and cast cleanly.
    expect(loaded.id, isNotEmpty);
    expect(loaded.conversationId, conversationId);
    expect(loaded.senderId, annClient!.auth.currentUser!.id);
    expect(loaded.isFrom(annClient!.auth.currentUser!.id), isTrue);
    expect(
      loaded.createdAt.isAfter(
        DateTime.now().subtract(const Duration(hours: 1)),
      ),
      isTrue,
      reason: 'created_at is assigned by the server and parsed as local time',
    );
  });

  test('the conversation list names the other member', () async {
    final body = 'preview ${DateTime.now().microsecondsSinceEpoch}';
    await ann.send(conversationId: conversationId, body: body);

    final list = (await ann.conversations() as Ok<dynamic>).value;
    final row = list.firstWhere((c) => c.id == conversationId);
    expect(row.other.userId, bobClient!.auth.currentUser!.id);
    expect(row.other.displayName, isNotEmpty);
    expect(row.lastMessage, body, reason: 'preview is the newest message');
    expect(row.lastMessageAt, isNotNull);
  });

  test('Realtime delivers a message to the other member', () async {
    final body = 'realtime ${DateTime.now().microsecondsSinceEpoch}';
    // Resolves only once the server has joined us, so no sleep is needed and
    // the send below cannot race the subscription.
    final opened = await bob.incoming(conversationId);
    expect(opened, isA<Ok<Stream<Message>>>(), reason: 'subscription refused');
    final received = (opened as Ok<Stream<Message>>).value
        .firstWhere((m) => m.body == body)
        .timeout(const Duration(seconds: 20));

    expect(
      await ann.send(conversationId: conversationId, body: body),
      isA<Ok>(),
    );

    final message = await received;
    expect(message.conversationId, conversationId);
    expect(message.senderId, annClient!.auth.currentUser!.id);
  });

  test('an empty body never reaches the database', () async {
    final before =
        (await ann.messages(conversationId) as Ok<List<Message>>).value.length;
    expect(
      await ann.send(conversationId: conversationId, body: '   '),
      isA<Err<void>>(),
    );
    final after =
        (await ann.messages(conversationId) as Ok<List<Message>>).value.length;
    expect(after, before);
  });

  test('a signed-in user who never activated a session is refused', () async {
    // Allowlisted, but no active session: has_app_access() is false, so RLS
    // returns nothing rather than erroring.
    final other = _client();
    addTearDown(other.dispose);
    await other.auth.signInWithPassword(
      email: 'bob@integration.test',
      password: _password,
    );
    // Signing in again created a NEWER session, which has not been activated,
    // so this client is not the active device.
    final repo = SupabaseChatRepository(other);
    final result = await repo.messages(conversationId);
    expect((result as Ok<List<Message>>).value, isEmpty);
  });

  group('deleteForEveryone', () {
    test(
      'a text message is wiped, and the other member sees it deleted',
      () async {
        final body = 'delete me ${DateTime.now().microsecondsSinceEpoch}';
        final sent = (await ann.send(
          conversationId: conversationId,
          body: body,
        )) as Ok<Message>;

        final deleted = await ann.deleteForEveryone(sent.value);
        expect(deleted, isA<Ok<void>>());

        final theirs =
            (await bob.messages(conversationId)) as Ok<List<Message>>;
        final seen = theirs.value.firstWhere((m) => m.id == sent.value.id);
        expect(seen.isDeleted, isTrue);
        expect(seen.body, isEmpty);
      },
    );

    test(
      'a photo message is removed from storage and forgotten by the cache',
      () async {
        final cache = _MemoryCache();
        final sender = SupabaseChatRepository(annClient!, cache: cache);
        final sent = await sender.sendImage(
          conversationId: conversationId,
          image: PickedImage(
            bytes: _png,
            contentType: 'image/png',
            extension: 'png',
          ),
        ) as Ok<Message>;
        final path = sent.value.attachmentPath!;
        expect(
          await cache.read(path),
          _png,
          reason: 'the sender caches her own upload immediately',
        );

        final deleted = await sender.deleteForEveryone(sent.value);
        expect(deleted, isA<Ok<void>>());

        expect(
          await cache.read(path),
          isNull,
          reason: 'the sender\'s own cache entry must be forgotten',
        );
        // The object itself is gone: a fresh read must fail, not find it.
        final reader = SupabaseChatRepository(bobClient!);
        final bytes = await reader.attachmentBytes(path);
        expect(
          bytes,
          isA<Err<Uint8List>>(),
          reason: 'the storage object was removed',
        );
      },
    );

    test('someone else\'s message cannot be deleted', () async {
      final body = 'not yours ${DateTime.now().microsecondsSinceEpoch}';
      final sent = (await ann.send(
        conversationId: conversationId,
        body: body,
      )) as Ok<Message>;

      final refused = await bob.deleteForEveryone(sent.value);
      expect(refused, isA<Err<void>>());
      expect((refused as Err<void>).failure, isA<DeniedFailure>());

      final after = (await ann.messages(conversationId)) as Ok<List<Message>>;
      final still = after.value.firstWhere((m) => m.id == sent.value.id);
      expect(still.isDeleted, isFalse);
      expect(still.body, body);
    });

    test(
      'the other member\'s incoming() stream delivers the wiped row live',
      () async {
        final opened = await bob.incoming(conversationId);
        expect(opened, isA<Ok<Stream<Message>>>());
        final stream = (opened as Ok<Stream<Message>>).value;

        // One subscription for the whole test: incoming() is not broadcast,
        // so a second `.firstWhere` on the same stream would throw.
        final events = <Message>[];
        final sub = stream.listen(events.add);
        addTearDown(sub.cancel);

        final body = 'watch me vanish ${DateTime.now().microsecondsSinceEpoch}';
        final sent = (await ann.send(
          conversationId: conversationId,
          body: body,
        )) as Ok<Message>;

        Future<void> until(bool Function() ok, String what) async {
          for (var i = 0; i < 150; i++) {
            if (ok()) return;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          fail('never happened: $what');
        }

        // The insert itself must arrive first, or the wiped row below would
        // be the only event bob's subscription ever saw for this id.
        await until(
          () => events.any((m) => m.id == sent.value.id && !m.isDeleted),
          'the insert to arrive over Realtime',
        );

        expect(await ann.deleteForEveryone(sent.value), isA<Ok<void>>());

        await until(
          () => events.any((m) => m.id == sent.value.id && m.isDeleted),
          'the wiped row to arrive over Realtime',
        );
        final wiped = events.firstWhere(
          (m) => m.id == sent.value.id && m.isDeleted,
        );
        expect(wiped.body, isEmpty);
      },
    );
  });
}
