// Seam: ConversationListController <-> REAL encrypted MessageStore <->
// ChatFake. From the Private Chats step 1 Group B contract:
// - list-wide live messages are upserted, those buffered while the first
//   list read is in flight included;
// - a chat missing from the server list, or hidden and then gone, gets
//   deleteConversation; a left group still on the server list stays;
// - (failure path) a failed list read purges nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'me', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

void main() {
  late StoreHarness h;
  late DriftMessageStore real;
  late SpyStore store;
  late ChatFake chat;
  late ProviderContainer c;

  Future<void> settle([int ms = 200]) =>
      Future<void>.delayed(Duration(milliseconds: ms));
  Future<List<String>> stored(String conv) async =>
      ids(await real.newest(conv, limit: 500));

  setUp(() async {
    h = await StoreHarness.create();
    real = h.open(owner: 'me', key: await h.newKey());
    store = SpyStore(real);
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        messageStoreProvider.overrideWithValue(store),
      ],
    );
    await real.upsertAll([
      msg('a1', conv: 'c1', t: 1),
      msg('b1', conv: 'c2', t: 2),
      msg('g1', conv: 'c3', t: 3),
    ]);
  });

  Future<void> load() async {
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    await settle();
  }

  ConversationListController list() =>
      c.read(conversationListProvider.notifier);

  group('purge', () {
    test('a chat missing from the server list is deleted; a left group still '
        'listed stays', () async {
      chat.conversationsResult = const Ok([
        Conversation(id: 'c1'),
        Conversation(id: 'c3', hasLeft: true),
      ]);
      await load();
      await eventually(() async => (await stored('c2')).isEmpty);
      expect(store.calls, contains('deleteConversation:c2'));
      expect(store.calls, isNot(contains('deleteConversation:c1')));
      expect(store.calls, isNot(contains('deleteConversation:c3')));
      expect(await stored('c1'), ['a1']);
      expect(await stored('c3'), ['g1'], reason: 'left, but still listed');
    });

    test(
      'a chat that drops off the server list on a refresh is deleted',
      () async {
        chat.conversationsResult = const Ok([
          Conversation(id: 'c1'),
          Conversation(id: 'c2'),
          Conversation(id: 'c3', hasLeft: true),
        ]);
        await load();
        expect(await stored('c2'), ['b1']);
        chat.conversationsResult = const Ok([
          Conversation(id: 'c1'),
          Conversation(id: 'c3', hasLeft: true),
        ]);
        await list().refresh();
        await eventually(() async => (await stored('c2')).isEmpty);
        expect(await stored('c1'), ['a1']);
        expect(await stored('c3'), ['g1'], reason: 'left, but still listed');
      },
    );

    test('hidden but still on the server: kept; then gone: deleted', () async {
      chat.conversationsResult = const Ok([
        Conversation(id: 'c1'),
        Conversation(id: 'c2'),
        Conversation(id: 'c3'),
      ]);
      await load();
      list().hideLocally(['c1']);
      await list().refresh();
      await settle();
      expect(await stored('c1'), ['a1'], reason: 'still on the server list');

      chat.conversationsResult = const Ok([
        Conversation(id: 'c2'),
        Conversation(id: 'c3'),
      ]);
      await list().refresh();
      await eventually(() async => (await stored('c1')).isEmpty);
      expect(store.calls, contains('deleteConversation:c1'));
    });

    test('a failed list read purges nothing', () async {
      chat.conversationsResult = const Err(NetworkFailure('offline'));
      c.listen(conversationListProvider, (_, _) {});
      await eventually(() => chat.calls.contains('conversations'));
      await settle();
      expect(store.count('deleteConversation'), 0);
      expect(await stored('c2'), ['b1']);
    });
  });

  group('live', () {
    test('a list-wide live message is upserted', () async {
      chat.conversationsResult = const Ok([
        Conversation(id: 'c1'),
        Conversation(id: 'c2'),
        Conversation(id: 'c3'),
      ]);
      await load();
      chat.deliver(msg('b2', conv: 'c2', t: 9, body: 'live'));
      await eventually(() async => (await stored('c2')).contains('b2'));
    });

    test(
      'a live message buffered during the first list read is upserted',
      () async {
        chat.conversationsResult = const Ok([
          Conversation(id: 'c1'),
          Conversation(id: 'c2'),
          Conversation(id: 'c3'),
        ]);
        chat.holdList();
        c.listen(conversationListProvider, (_, _) {});
        await eventually(() => chat.calls.contains('incomingAll'));
        await eventually(() => chat.calls.contains('conversations'));
        await settle(50);
        chat.deliver(msg('b3', conv: 'c2', t: 10, body: 'buffered'));
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await eventually(() async => (await stored('c2')).contains('b3'));
      },
    );
  });
}
