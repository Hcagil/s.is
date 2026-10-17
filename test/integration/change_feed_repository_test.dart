@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// The store catch-up reads against the real local stack: changesSince
/// (keyset paging by updated_at then id), newestChange and messagesBefore.
/// The keyset filter, the tie branch and the at-or-before boundary are
/// PostgREST query shaping that a fake cannot show.
///
/// Requires `docker compose run --rm supabase start`. ann, bob and fay are this
/// suite's own allowlisted accounts (supabase/seed.sql); fay is in no chat
/// with them.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _minId = '00000000-0000-0000-0000-000000000000';
const _maxId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => fail('expected Ok, got ${failure.message}'),
};

List<String> _ids(Iterable<Message> ms) => [for (final m in ms) m.id];

void main() {
  late SupabaseClient annClient;
  late SupabaseChatRepository ann;
  late SupabaseChatRepository fay;
  late String chat;
  late ChangeCursor start;

  /// Seeded rows of [chat], oldest first (one insert each, so both created_at
  /// and updated_at ascend).
  final ids = <String>[];

  setUpAll(() async {
    annClient = await _signedIn('cf-ann@mail.test');
    final bobClient = await _signedIn('cf-bob@mail.test');
    final fayClient = await _signedIn('cf-fay@mail.test');
    ann = SupabaseChatRepository(annClient);
    fay = SupabaseChatRepository(fayClient);
    await findByTag(annClient, [bobClient]);
    // A fresh group per run: no earlier run's rows in it.
    chat = _ok(
      await ann.startGroupConversation(
        title: 'feed ${DateTime.now().microsecondsSinceEpoch}',
        memberIds: [bobClient.auth.currentUser!.id],
      ),
    );
    // The feed is account-wide: start after everything ann could already read.
    start =
        _ok(await ann.newestChange()) ??
        ChangeCursor(DateTime.utc(2000), _minId);
    for (var i = 0; i < 6; i++) {
      final id = randomMessageId();
      await annClient.from('messages').insert({
        'id': id,
        'conversation_id': chat,
        'sender_id': annClient.auth.currentUser!.id,
        'body': 'feed-row $i',
      });
      ids.add(id);
    }
  });

  tearDownAll(() async {
    await annClient.dispose();
  });

  late ChangePage p1;

  test('pages ascend from the cursor; a full page may have more; an empty '
      'page has no last cursor', () async {
    p1 = _ok(await ann.changesSince(start, limit: 3));
    expect(_ids(p1.messages), ids.sublist(0, 3));
    expect(p1.last?.id, ids[2], reason: 'last = cursor of the final row');

    final p2 = _ok(await ann.changesSince(p1.last!, limit: 3));
    expect(
      _ids(p2.messages),
      ids.sublist(3, 6),
      reason: 'exactly limit rows; the cursor advanced past page 1',
    );
    expect(p2.last?.id, ids[5]);
    expect(p2.last!.updatedAt.isAfter(p1.last!.updatedAt), isTrue);

    final p3 = _ok(await ann.changesSince(p2.last!, limit: 3));
    expect(p3.messages, isEmpty);
    expect(p3.last, isNull);
  });

  test('a row sharing the cursor time is paged by id', () async {
    final t = p1.last!.updatedAt;
    final smaller = _ok(
      await ann.changesSince(ChangeCursor(t, _minId), limit: 1),
    );
    expect(_ids(smaller.messages), [
      ids[2],
    ], reason: 'same updated_at, larger id: after the cursor');
    final larger = _ok(
      await ann.changesSince(ChangeCursor(t, _maxId), limit: 1),
    );
    expect(_ids(larger.messages), [
      ids[3],
    ], reason: 'same updated_at, smaller id: not after the cursor');
    final same = _ok(await ann.changesSince(ChangeCursor(t, ids[2]), limit: 1));
    expect(_ids(same.messages), [ids[3]], reason: 'the cursor row itself');
  });

  test('newestChange is the cursor of the newest readable change', () async {
    final newest = _ok(await ann.newestChange());
    expect(newest?.id, ids.last);
    final after = _ok(await ann.changesSince(newest!));
    expect(after.messages, isEmpty);
  });

  test('an edit and a delete-for-everyone come back after the cursor, in '
      'order', () async {
    final before = _ok(await ann.newestChange())!;
    final rows = _ok(await ann.messages(chat));
    Message row(String id) => rows.firstWhere((m) => m.id == id);
    _ok(await ann.editMessage(row(ids[0]), 'feed-row 0 edited'));
    _ok(await ann.deleteForEveryone(row(ids[1])));

    final page = _ok(await ann.changesSince(before));
    expect(_ids(page.messages), [ids[0], ids[1]]);
    expect(page.messages[0].body, 'feed-row 0 edited');
    expect(page.messages[1].deletion, isNotNull);
    expect(page.last?.id, ids[1]);
  });

  test('a non-member reads none of the chat', () async {
    final feed = _ok(
      await fay.changesSince(ChangeCursor(DateTime.utc(2000), _minId)),
    );
    expect(feed.messages.where((m) => m.conversationId == chat), isEmpty);
    final newest = _ok(await fay.newestChange());
    expect(ids, isNot(contains(newest?.id)));
    final before = _ok(
      await fay.messagesBefore(
        chat,
        DateTime.now().add(const Duration(days: 1)),
      ),
    );
    expect(before, isEmpty);
  });

  test('messagesBefore: the newest limit rows at or before the instant, '
      'oldest first', () async {
    final all = _ok(await ann.messages(chat));
    final pivot = all.firstWhere((m) => m.id == ids[3]).createdAt;
    final atOrBefore = all.where((m) => !m.createdAt.isAfter(pivot)).toList();

    final two = _ok(await ann.messagesBefore(chat, pivot, limit: 2));
    expect(_ids(two), [
      ids[2],
      ids[3],
    ], reason: 'boundary row included; the newest two, oldest first');

    final wide = _ok(await ann.messagesBefore(chat, pivot, limit: 50));
    expect(_ids(wide), _ids(atOrBefore));

    final first = all.firstWhere((m) => m.id == ids[0]).createdAt;
    final none = _ok(
      await ann.messagesBefore(
        chat,
        first.subtract(const Duration(microseconds: 1)),
      ),
    );
    expect(none.where((m) => ids.contains(m.id)), isEmpty);
  });
}
