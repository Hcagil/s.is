@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// 0.30.8, against the real local stack, from the ChatRepository contract:
///  * hideForMe hides a message from the caller's own reads only; the
///    server refuses (DeniedFailure) a message the caller cannot read;
///  * unreadTotal counts what the member has not read, across chats;
///  * deleteForEveryone of a photo message is Ok even when the photo's
///    storage object is already gone (storage remove returns nothing).
///
/// Uses its own accounts (signing in claims the device). Run after
/// realtime_warmup_test.dart with --concurrency=1, like the rest.
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
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: '$r');
  return (r as Ok<T>).value;
}

void main() {
  HttpOverrides.global = null;

  late SupabaseClient giaC, holC, ikeC;
  late SupabaseChatRepository gia, hol, ike;
  late String chat;

  setUpAll(() async {
    giaC = await _signedIn('gia@integration.test');
    holC = await _signedIn('hol@integration.test');
    ikeC = await _signedIn('ike@integration.test');
    gia = SupabaseChatRepository(giaC);
    hol = SupabaseChatRepository(holC);
    ike = SupabaseChatRepository(ikeC);
    await findByTag(giaC, [holC]);
    chat = _ok(await gia.startDirectConversation(holC.auth.currentUser!.id));
  });

  tearDownAll(() async {
    await giaC.dispose();
    await holC.dispose();
    await ikeC.dispose();
  });

  Future<Message> say(SupabaseChatRepository who, String body) async => _ok(
    await who.send(id: randomMessageId(), conversationId: chat, body: body),
  );

  Future<List<String>> ids(SupabaseChatRepository who) async => [
    for (final m in _ok(await who.messages(chat))) m.id,
  ];

  group('hideForMe', () {
    test('hidden for the hider on a fresh read, untouched for the other '
        'member', () async {
      final m = await say(hol, 'hide me ${DateTime.now()}');
      expect(await ids(gia), contains(m.id));

      _ok(await gia.hideForMe(m));

      expect(await ids(gia), isNot(contains(m.id)));
      final forHol = _ok(await hol.messages(chat));
      final seen = forHol.singleWhere((x) => x.id == m.id);
      expect(seen.isDeleted, isFalse, reason: 'nobody else sees any change');
      expect(seen.body, m.body);
    });

    test('a member may hide their own message too', () async {
      final m = await say(gia, 'mine ${DateTime.now()}');
      _ok(await gia.hideForMe(m));
      expect(await ids(gia), isNot(contains(m.id)));
      expect(await ids(hol), contains(m.id));
    });

    test(
      'a message the caller cannot read is refused (DeniedFailure)',
      () async {
        final m = await say(hol, 'not for ike ${DateTime.now()}');
        final r = await ike.hideForMe(m);
        expect(r, isA<Err<void>>());
        expect((r as Err<void>).failure, isA<DeniedFailure>());
        expect(await ids(gia), contains(m.id), reason: 'nothing changed');
      },
    );
  });

  group('unreadTotal', () {
    test('rises with what arrives, falls to 0 when read', () async {
      _ok(await gia.markRead(chat));
      final base = _ok(await gia.unreadTotal());
      final senderBase = _ok(await hol.unreadTotal());

      await say(hol, 'one');
      await say(hol, 'two');
      expect(_ok(await gia.unreadTotal()), base + 2);
      expect(
        _ok(await hol.unreadTotal()),
        senderBase,
        reason: 'own messages are not unread for the sender',
      );

      _ok(await gia.markRead(chat));
      expect(_ok(await gia.unreadTotal()), 0);
    });

    test('a hidden unread message no longer counts', () async {
      _ok(await gia.markRead(chat));
      final m = await say(hol, 'gone soon');
      await say(hol, 'stays');
      expect(_ok(await gia.unreadTotal()), 2);

      _ok(await gia.hideForMe(m));
      expect(_ok(await gia.unreadTotal()), 1);
    });
  });

  group('deleteForEveryone of a photo (F1)', () {
    late SupabaseClient service;
    setUpAll(() => service = _client(serviceKey()));
    tearDownAll(() => service.dispose());

    Future<bool> stored(String path) async {
      final slash = path.lastIndexOf('/');
      final files = await service.storage
          .from('attachments')
          .list(path: path.substring(0, slash));
      return files.any((f) => f.name == path.substring(slash + 1));
    }

    Future<Message> photo() async => _ok(
      await hol.sendImage(
        conversationId: chat,
        image: PickedImage(
          bytes: _png,
          contentType: 'image/png',
          extension: 'png',
        ),
      ),
    );

    test('the sender deleting a photo removes its object', () async {
      final m = await photo();
      expect(await stored(m.attachmentPath!), isTrue);

      _ok(await hol.deleteForEveryone(m));

      expect(await stored(m.attachmentPath!), isFalse);
      final seen = _ok(await gia.messages(chat)).where((x) => x.id == m.id);
      expect(seen.single.isDeleted, isTrue);
    });

    test('the object already gone (remove returns nothing): still Ok, the '
        'message still deleted', () async {
      final m = await photo();
      await service.storage.from('attachments').remove([m.attachmentPath!]);
      expect(await stored(m.attachmentPath!), isFalse);

      final r = await hol.deleteForEveryone(m);

      expect(r, isA<Ok<void>>(), reason: '$r');
      final seen = _ok(await gia.messages(chat)).where((x) => x.id == m.id);
      expect(seen.single.isDeleted, isTrue);
    });
  });
}
