// The three store writers and the vanished tombstone, from the QA interface:
// StoreSyncController._write, MessagesController._persist and
// ConversationListController._persist send a `vanished` row to
// VanishedStore.markVanished(id, conversationId); a placeholder deletion and
// a hidden-for-me remove write NO tombstone; a store without VanishedStore
// gets plain remove(id); vanishedIdsProvider follows a tombstone written
// while it is watched (no reopen). Fakes are the QA lead's own.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/vanished_store.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/drift_stores.dart';
import '../../support/fakes.dart';
import '../../support/peer_key_fakes.dart' show MemoryMessageStore;
import '../../support/store_spy.dart' show eventually;
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

const _me = Member(userId: 'u1', displayName: 'Maya');
final _cursor = ChangeCursor(at(100), 'seed');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

/// A store that keeps no tombstones: logs the writes.
class _Plain extends MemoryMessageStore {
  final log = <String>[];
  @override
  Future<void> remove(String messageId) {
    log.add('remove:$messageId');
    return super.remove(messageId);
  }

  @override
  Future<void> upsertAll(List<Message> messages) {
    log.add('upsert:${[for (final m in messages) m.id].join(',')}');
    return super.upsertAll(messages);
  }

  // A saved cursor makes StoreSyncController start from the change feed.
  @override
  Future<ChangeCursor?> cursor() async => _cursor;
}

class _Tomb extends _Plain implements VanishedStore {
  @override
  Future<void> markVanished(String messageId, String conversationId) async {
    log.add('vanish:$conversationId:$messageId');
    rows.remove(messageId);
  }

  @override
  Future<Set<String>> vanishedIds(String conversationId) async => {};
}

/// The server: a change feed that answers one page of rows once.
class _Feed extends ChatFake {
  List<Message> page = const [];
  bool served = false;

  @override
  Future<Result<ChangePage>> changesSince(
    ChangeCursor cursor, {
    int limit = 500,
  }) async {
    if (served || page.isEmpty) return const Ok(ChangePage([], null));
    served = true;
    return Ok(ChangePage(page, ChangeCursor(at(200), page.last.id)));
  }
}

Message _m(
  String id, {
  String conv = 'c1',
  MessageDeletion? d,
  String from = 'u2',
  DateTime? when,
}) => Message(
  id: id,
  conversationId: conv,
  senderId: from,
  body: d == null ? 'text' : '',
  createdAt: when ?? DateTime.now(),
  deletion: d,
);

ProviderContainer _scope(ChatFake chat, List<Override> store) =>
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        ...store,
      ],
    );

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  const vanished = MessageDeletion.vanished;
  const placeholder = MessageDeletion.placeholder;

  group('ConversationListController', () {
    Future<(ProviderContainer, ChatFake)> boot(MessageStore store) async {
      final chat = ChatFake()
        ..conversationsResult = const Ok([Conversation(id: 'c1')]);
      final c = _scope(chat, [messageStoreProvider.overrideWithValue(store)]);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      await eventually(() => chat.liveAllListeners > 0, reason: 'the join');
      return (c, chat);
    }

    test('a vanished row is marked vanished with its chat', () async {
      final store = _Tomb();
      final (_, chat) = await boot(store);
      chat.deliver(_m('m1', d: vanished));
      await _settle();
      expect(store.log, contains('vanish:c1:m1'));
      expect(store.log.where((l) => l.startsWith('remove')), isEmpty);
    });

    test('a placeholder writes no tombstone', () async {
      final store = _Tomb();
      final (_, chat) = await boot(store);
      chat.deliver(_m('m1', d: placeholder));
      await _settle();
      expect(store.log, ['upsert:m1']);
    });

    test('a store without tombstones gets remove(id)', () async {
      final store = _Plain();
      final (_, chat) = await boot(store);
      chat.deliver(_m('m1', d: vanished));
      await _settle();
      expect(store.log, ['remove:m1']);
    });
  });

  group('MessagesController', () {
    Future<(ProviderContainer, ChatFake)> boot(MessageStore store) async {
      final chat = ChatFake()
        ..history['c1'] = [_m('seed', when: DateTime(2020))];
      final c = _scope(chat, [messageStoreProvider.overrideWithValue(store)]);
      c.listen(currentUserIdProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      c.listen(openConversationProvider, (_, _) {});
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      chat.confirmSubscription();
      await _settle();
      return (c, chat);
    }

    test('a vanished row from Realtime is marked vanished', () async {
      final store = _Tomb();
      final (_, chat) = await boot(store);
      store.log.clear();
      chat.deliver(_m('m1', d: vanished));
      await _settle();
      expect(store.log, contains('vanish:c1:m1'));
    });

    test('my own recent delete (a vanish) is marked vanished', () async {
      final store = _Tomb();
      final (c, chat) = await boot(store);
      chat.deleteForEveryoneResult = const Ok(null);
      store.log.clear();
      await c
          .read(messagesProvider.notifier)
          .deleteForEveryone(_m('m2', from: 'u1'));
      await _settle();
      expect(store.log, contains('vanish:c1:m2'));
    });

    test(
      'a placeholder delete (old own message) writes no tombstone',
      () async {
        final store = _Tomb();
        final (c, chat) = await boot(store);
        chat.deleteForEveryoneResult = const Ok(null);
        store.log.clear();
        await c
            .read(messagesProvider.notifier)
            .deleteForEveryone(_m('m3', from: 'u1', when: DateTime(2020)));
        await _settle();
        expect(store.log, ['upsert:m3']);
      },
    );

    test('hide for me removes the row and writes no tombstone', () async {
      final store = _Tomb();
      final (c, chat) = await boot(store);
      chat.hideForMeResult = const Ok(null);
      store.log.clear();
      await c.read(messagesProvider.notifier).hideForMe(_m('m4'));
      await _settle();
      expect(store.log, ['remove:m4']);
    });

    test(
      'a store without tombstones gets remove(id) for a vanished row',
      () async {
        final store = _Plain();
        final (_, chat) = await boot(store);
        store.log.clear();
        chat.deliver(_m('m1', d: vanished));
        await _settle();
        expect(store.log, ['remove:m1']);
      },
    );
  });

  group('StoreSyncController', () {
    Future<void> sync(MessageStore store, Message row) async {
      final feed = _Feed()..page = [row];
      final c = _scope(feed, [messageStoreProvider.overrideWithValue(store)]);
      c.listen(currentUserIdProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      await c.read(storeSyncProvider).run();
      await _settle();
    }

    test('a vanished feed row is marked vanished with its chat', () async {
      final store = _Tomb();
      await sync(store, _m('f1', conv: 'c7', d: vanished));
      expect(store.log, contains('vanish:c7:f1'));
    });

    test('a placeholder feed row writes no tombstone', () async {
      final store = _Tomb();
      await sync(store, _m('f2', conv: 'c7', d: placeholder));
      expect(store.log.where((l) => l.startsWith('vanish')), isEmpty);
      expect(store.log.any((l) => l.contains('f2')), isTrue);
    });

    test('a store without tombstones gets remove(id)', () async {
      final store = _Plain();
      await sync(store, _m('f3', conv: 'c7', d: vanished));
      expect(store.log, contains('remove:f3'));
    });
  });

  group('vanishedIdsProvider', () {
    test('no store, or a store without tombstones: empty set', () async {
      final plain = _scope(ChatFake(), [
        messageStoreProvider.overrideWithValue(_Plain()),
      ]);
      expect(await plain.read(vanishedIdsProvider('c1').future), isEmpty);
      final none = _scope(ChatFake(), const []);
      expect(await none.read(vanishedIdsProvider('c1').future), isEmpty);
    });

    test('a tombstone written while watched shows without reopening', () async {
      final h = await StoreHarness.create();
      final key = await h.newKey();
      final chat = ChatFake()
        ..conversationsResult = const Ok([Conversation(id: 'c1')]);
      final c = _scope(chat, driftStoreOverrides(Directory(h.dir.path), key));
      addTearDown(() => quit(c));
      c.listen(conversationListProvider, (_, _) {});
      final seen = <Set<String>>[];
      c.listen(vanishedIdsProvider('c1'), (_, n) {
        if (n.hasValue) seen.add(n.value!);
      }, fireImmediately: true);
      await c.read(conversationListProvider.future);
      await eventually(() => chat.liveAllListeners > 0, reason: 'the join');
      expect(await c.read(vanishedIdsProvider('c1').future), isEmpty);

      chat.deliver(_m('m9', d: vanished));
      await eventually(
        () => seen.isNotEmpty && seen.last.contains('m9'),
        reason: 'the quote set never updated',
      );
      expect(await c.read(vanishedIdsProvider('c1').future), {'m9'});
    });
  });
}
