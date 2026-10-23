// Seam: ConversationListController <-> REAL encrypted DriftMessageStore (and
// the REAL DriftChatListSnapshotStore over it) <-> ChatFake. Written from the
// t_344c8711cf QA interface, never from the implementation:
// - a server preview that is the locked placeholder, last at T, shows the
//   text of a stored readable, non-deleted message created at exactly T;
//   otherwise the placeholder stays;
// - unlockPreviews re-reads the phone's copies, no network, saves the snapshot;
// - a reopened (now readable) live message for the same createdAt upgrades
//   the preview without moving the chat or counting it unread again;
// - an older message never replaces a newer preview;
// - a store that fails, or no store at all, leaves the placeholder, no crash.
// Times are UTC with microseconds, as the server sends them; run under
// TZ=JST-9 so a store that hands times back in local time is caught.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'me', displayName: 'Maya');
const _deniz = Member(userId: 'u2', displayName: 'Deniz');
const _lock = lockedBodyPlaceholder;

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

/// The real store, except every newest() read fails, as a broken disk does.
class _BrokenReads extends SpyStore {
  _BrokenReads(super.inner);
  @override
  Future<List<Message>> newest(String conversationId, {int limit = 50}) async {
    calls.add('newest:$conversationId');
    throw StateError('disk read failed');
  }
}

/// A server preview of [id]: last message at minute [t] from Deniz.
Conversation _chat(String id, String text, int t, {int unread = 0}) =>
    Conversation(
      id: id,
      other: _deniz,
      lastMessage: text,
      lastMessageAt: at(t),
      lastSenderId: _deniz.userId,
      unread: unread,
    );

void main() {
  late StoreHarness h;
  late String key;
  late DriftMessageStore real;
  late SpyStore store;
  late ChatFake chat;
  late ProviderContainer c;

  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  ProviderContainer boot({MessageStore? withStore, bool noStore = false}) {
    final container = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        if (!noStore) ...[
          messageStoreProvider.overrideWithValue(withStore ?? store),
          chatListSnapshotStoreProvider.overrideWithValue(
            DriftChatListSnapshotStore(real),
          ),
        ],
      ],
    );
    return container;
  }

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    real = h.open(owner: 'me', key: key);
    addTearDown(real.close);
    store = SpyStore(real);
    chat = ChatFake(latency: const Duration(milliseconds: 2));
  });

  Future<List<Conversation>> load([ProviderContainer? on]) async {
    final x = on ?? c;
    x.listen(conversationListProvider, (_, _) {});
    await x.read(conversationListProvider.future);
    // The first value may be the phone's snapshot; wait for the server's.
    await eventually(() {
      final s = x.read(conversationListProvider);
      return s.hasValue && !s.isLoading;
    }, reason: 'list loaded');
    await settle();
    return x.read(conversationListProvider).value!;
  }

  ConversationListController list() =>
      c.read(conversationListProvider.notifier);
  Conversation shown(String id) =>
      c.read(conversationListProvider).value!.firstWhere((x) => x.id == id);
  int listReads() => chat.calls.where((x) => x == 'conversations').length;

  group('(2) received and opened on this phone', () {
    test('the list load shows the stored text, unread kept', () async {
      await real.upsertAll([
        msg('m1', conv: 'c1', t: 5, sender: 'u2', body: 'see you at nine'),
      ]);
      chat.conversationsResult = Ok([_chat('c1', _lock, 5, unread: 2)]);
      c = boot();
      await load();
      expect(shown('c1').lastMessage, 'see you at nine');
      expect(shown('c1').unread, 2);
      expect(shown('c1').lastMessageAt, at(5));
    });

    test('a reopened live message for the same createdAt upgrades the '
        'preview; order and unread unchanged', () async {
      chat.conversationsResult = Ok([
        _chat('c1', 'newer chat', 9, unread: 1),
        _chat('c2', _lock, 5, unread: 2),
      ]);
      c = boot();
      await load();
      expect(shown('c2').lastMessage, _lock, reason: 'setup: not opened yet');

      final opened = msg('m2', conv: 'c2', t: 5, sender: 'u2', body: 'hi');
      await real.upsertAll([opened]);
      chat.deliver(opened);
      await eventually(() => shown('c2').lastMessage == 'hi');
      final now = c.read(conversationListProvider).value!;
      expect([for (final x in now) x.id], ['c1', 'c2']);
      expect(shown('c2').unread, 2, reason: 'a reopen is not a new message');
      expect(shown('c1').unread, 1);
    });

    test('unlockPreviews shows text that landed in the store, with no '
        'network call, and saves it to the snapshot', () async {
      chat.conversationsResult = Ok([_chat('c1', _lock, 5, unread: 1)]);
      c = boot();
      await load();
      expect(shown('c1').lastMessage, _lock);
      final reads = listReads();

      await real.upsertAll([
        msg('m1', conv: 'c1', t: 5, sender: 'u2', body: 'opened later'),
      ]);
      await list().unlockPreviews();
      await settle();
      expect(shown('c1').lastMessage, 'opened later');
      expect(shown('c1').unread, 1);
      expect(listReads(), reads, reason: 'unlockPreviews read the network');
      // The snapshot write is allowed to trail the state change.
      await eventually(() async {
        final saved = await DriftChatListSnapshotStore(real).load('me');
        return saved?.single.lastMessage == 'opened later';
      }, reason: 'snapshot still holds the placeholder');
    });

    test('unlockPreviews while the list is still loading does nothing and '
        'does not throw', () async {
      chat.conversationsResult = Ok([_chat('c1', _lock, 5)]);
      chat.holdList();
      c = boot();
      c.listen(conversationListProvider, (_, _) {});
      await eventually(() => chat.calls.contains('conversations'));
      await list().unlockPreviews();
      expect(c.read(conversationListProvider).isLoading, isTrue);
      chat.releaseList();
      await c.read(conversationListProvider.future);
      expect(shown('c1').lastMessage, _lock);
    });
  });

  group('(3) received but not openable: the placeholder stays', () {
    for (final (name, rows) in [
      ('nothing stored', <Message>[]),
      (
        'only the placeholder stored',
        [msg('m1', conv: 'c1', t: 5, sender: 'u2', body: _lock)],
      ),
      (
        'readable text stored, but from another time',
        [msg('m0', conv: 'c1', t: 4, sender: 'u2', body: 'an older line')],
      ),
      (
        'the message at T was deleted',
        [
          msg(
            'm1',
            conv: 'c1',
            t: 5,
            sender: 'u2',
            body: 'gone',
            deletion: MessageDeletion.placeholder,
          ),
        ],
      ),
    ]) {
      test(name, () async {
        await real.upsertAll(rows);
        chat.conversationsResult = Ok([_chat('c1', _lock, 5)]);
        c = boot();
        await load();
        expect(shown('c1').lastMessage, _lock);
        await list().unlockPreviews();
        expect(shown('c1').lastMessage, _lock);
      });
    }
  });

  test('(4) app restart: the snapshot holds the placeholder, the store the '
      'text: after load the text shows', () async {
    await DriftChatListSnapshotStore(real)
        .save('me', [_chat('c1', _lock, 5, unread: 1)]);
    await real.upsertAll([
      msg('m1', conv: 'c1', t: 5, sender: 'u2', body: 'kept on the phone'),
    ]);
    chat.conversationsResult = Ok([_chat('c1', _lock, 5, unread: 1)]);
    c = boot();
    await load();
    expect(shown('c1').lastMessage, 'kept on the phone');
    await list().reloadQuietly();
    await settle();
    expect(shown('c1').lastMessage, 'kept on the phone');
    await list().refresh();
    await settle();
    expect(shown('c1').lastMessage, 'kept on the phone');
  });

  group('(5) realtime', () {
    test(
      'a newer locked message not in the store shows the placeholder',
      () async {
        await real.upsertAll([
          msg('m1', conv: 'c1', t: 5, sender: 'u2', body: 'old readable'),
        ]);
        chat.conversationsResult = Ok([_chat('c1', _lock, 5)]);
        c = boot();
        await load();
        expect(shown('c1').lastMessage, 'old readable', reason: 'setup');
        chat.deliver(msg('m2', conv: 'c1', t: 9, sender: 'u2', body: _lock));
        await eventually(() => shown('c1').lastMessageAt == at(9));
        expect(shown('c1').lastMessage, _lock);
      },
    );

    test('an older reopened message never replaces a newer preview', () async {
      chat.conversationsResult = Ok([_chat('c1', _lock, 9, unread: 1)]);
      c = boot();
      await load();
      final older = msg('m1', conv: 'c1', t: 3, sender: 'u2', body: 'older');
      await real.upsertAll([older]);
      chat.deliver(older);
      await settle();
      await list().unlockPreviews();
      expect(shown('c1').lastMessage, _lock);
      expect(shown('c1').lastMessageAt, at(9));
      expect(shown('c1').unread, 1);
    });

    test('an older readable message never replaces a newer text', () async {
      chat.conversationsResult = Ok([_chat('c1', 'newest', 9)]);
      c = boot();
      await load();
      chat.deliver(msg('m1', conv: 'c1', t: 3, sender: 'u2', body: 'older'));
      await settle();
      expect(shown('c1').lastMessage, 'newest');
    });
  });

  group('(7) failure paths', () {
    test('a store read error: the placeholder stays, no crash, no extra '
        'network call', () async {
      await real.upsertAll([
        msg('m1', conv: 'c1', t: 5, sender: 'u2', body: 'unreachable'),
      ]);
      final broken = _BrokenReads(real);
      chat.conversationsResult = Ok([_chat('c1', _lock, 5)]);
      c = boot(withStore: broken);
      final shownList = await load();
      expect(broken.count('newest'), greaterThan(0), reason: 'setup: read');
      expect(shownList.single.lastMessage, _lock);
      final reads = listReads();
      await list().unlockPreviews();
      expect(shown('c1').lastMessage, _lock);
      expect(listReads(), reads);
      expect(c.read(conversationListProvider).hasError, isFalse);
    });

    test('no store configured: the placeholder stays, no crash', () async {
      chat.conversationsResult = Ok([_chat('c1', _lock, 5)]);
      c = boot(noStore: true);
      await load();
      expect(shown('c1').lastMessage, _lock);
      final reads = listReads();
      await list().unlockPreviews();
      expect(shown('c1').lastMessage, _lock);
      expect(listReads(), reads);
    });
  });
}
