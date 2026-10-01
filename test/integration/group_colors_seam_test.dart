@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// Group sender colours (0.30.7) through the real repository and the real
/// list controller: the server's color_slot (assigned by its trigger) and the
/// profile names reach Conversation.senders and GroupMember.colorSlot; a 1:1
/// and the SIS chat carry no senders; a message from someone the list does
/// not know yet makes the list read itself again rather than show a stale,
/// unnamed preview.
///
/// gwen/hugh/iona are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

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

Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 25),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (matches(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out after $timeout: $reason');
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

T ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => fail('refused: ${failure.message}'),
};

void main() {
  SupabaseClient? gwenClient, hughClient, ionaClient, service;
  late SupabaseChatRepository gwen, hugh, iona;
  late String hughId, ionaId;
  final notes = <int>[];

  Future<String> nameOf(SupabaseClient c) async =>
      (await c
              .from('profiles')
              .select('display_name')
              .eq('user_id', c.auth.currentUser!.id)
              .single())['display_name']
          as String;

  setUpAll(() async {
    service = _client(serviceKey());
    hughClient = await _signedIn('hugh@integration.test');
    ionaClient = await _signedIn('iona@integration.test');
    gwenClient = await _signedIn('gwen@integration.test');
    gwen = SupabaseChatRepository(gwenClient!);
    hugh = SupabaseChatRepository(hughClient!);
    iona = SupabaseChatRepository(ionaClient!);
    hughId = hughClient!.auth.currentUser!.id;
    ionaId = ionaClient!.auth.currentUser!.id;
    await findByTag(gwenClient!, [hughClient!, ionaClient!]);

    // gwen's SIS chat, so the system chat is in her list.
    final base =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1700000000) * 10 + 5;
    await gwenClient!.rpc(
      'deliver_release_notes',
      params: {'installed_build': base},
    );
    await service!.from('release_notes').insert({
      'build': base + 1,
      'note': _stamp('note'),
    });
    notes.add(base + 1);
    await gwenClient!.rpc(
      'deliver_release_notes',
      params: {'installed_build': base + 1},
    );
  });

  tearDownAll(() async {
    if (notes.isNotEmpty) {
      await service?.from('release_notes').delete().inFilter('build', notes);
    }
    for (final c in [gwenClient, hughClient, ionaClient, service]) {
      await c?.dispose();
    }
  });

  ProviderContainer container() => ProviderContainer.test(
    overrides: [chatRepositoryProvider.overrideWithValue(gwen)],
  );

  test('a group: senders carry the server slots and profile names, the same '
      'slots as the roster; the 1:1 and the SIS chat carry none', () async {
    final group = ok(
      await gwen.startGroupConversation(
        title: _stamp('colours'),
        memberIds: [hughId, ionaId],
      ),
    );
    final direct = ok(await gwen.startDirectConversation(hughId));
    expect(
      await hugh.send(
        id: randomMessageId(),
        conversationId: direct,
        body: 'hi',
      ),
      isA<Ok<Message>>(),
    );

    final roster = ok(await gwen.groupRoster(group));
    final slotOf = {for (final g in roster) g.member.userId: g.colorSlot};
    expect(slotOf.values.toSet(), {
      0,
      1,
      2,
    }, reason: 'three people joined a fresh group: slots 0, 1 and 2');

    final list = ok(await gwen.conversations());
    final row = list.singleWhere((c) => c.id == group);
    expect(row.senders.keys, containsAll([hughId, ionaId]));
    expect(row.senders[hughId]!.name, await nameOf(hughClient!));
    expect(row.senders[ionaId]!.name, await nameOf(ionaClient!));
    expect(row.senders[hughId]!.slot, slotOf[hughId]);
    expect(row.senders[ionaId]!.slot, slotOf[ionaId]);

    expect(list.singleWhere((c) => c.id == direct).senders, isEmpty);
    final sis = list.where((c) => c.isSystem).toList();
    expect(sis, hasLength(1), reason: "gwen's SIS chat is in her list");
    expect(sis.single.senders, isEmpty);
  });

  test('a member who leaves keeps their slot in the roster, and a newcomer '
      'does not take it', () async {
    final group = ok(
      await gwen.startGroupConversation(
        title: _stamp('leaving'),
        memberIds: [hughId],
      ),
    );
    final before = {
      for (final g in ok(await gwen.groupRoster(group)))
        g.member.userId: g.colorSlot,
    };
    ok(await hugh.leaveGroup(group));
    ok(await gwen.addMembers(group, [ionaId], withHistory: true));

    final after = ok(await gwen.groupRoster(group));
    GroupMember of(String id) => after.singleWhere(
      (g) => g.member.userId == id && (id != hughId || g.leftReason != null),
    );
    expect(of(hughId).colorSlot, before[hughId], reason: 'hugh keeps his');
    expect(
      of(ionaId).colorSlot,
      isNot(anyOf(before[hughId], before[gwenClient!.auth.currentUser!.id])),
      reason: "iona took a slot someone still holds",
    );
  });

  test('a message from someone added after the list was read: the list reads '
      'again and can name them', () async {
    final group = ok(
      await gwen.startGroupConversation(
        title: _stamp('newcomer'),
        memberIds: [hughId],
      ),
    );
    final c = container();
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    // Every channel gwen holds has joined, so the insert below reaches her.
    await eventually<List<RealtimeChannel>>(
      () => gwenClient!.getChannels(),
      (cs) => cs.isNotEmpty && cs.every((x) => x.canPush),
      reason: 'the list subscription never joined',
    );
    Conversation? row() => c
        .read(conversationListProvider)
        .value
        ?.where((x) => x.id == group)
        .firstOrNull;
    expect(row()!.senders.containsKey(ionaId), isFalse);

    ok(await gwen.addMembers(group, [ionaId], withHistory: true));
    final body = _stamp('from the newcomer');
    expect(
      await iona.send(id: randomMessageId(), conversationId: group, body: body),
      isA<Ok<Message>>(),
    );
    final seen = await eventually<Conversation?>(
      row,
      (r) =>
          r != null && r.lastMessage == body && r.senders.containsKey(ionaId),
      reason: 'the list never learned who wrote the newest message',
    );
    expect(seen!.senders[ionaId]!.name, await nameOf(ionaClient!));
  });
}
