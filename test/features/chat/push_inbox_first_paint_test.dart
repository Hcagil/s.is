// Seam: the notification's push_inbox rows (written by the REAL push writer,
// writePushInbox, into the REAL encrypted store file) -> the chat list and a
// chat's first paint, with the stores wired as lib/main.dart wires them
// (driftStoreOverrides) and a ChatFake server that is held open.
// Written from the slice 2 contract (t_428ad7c883), never from the code:
// - list, cached path: push rows apply as a new message would (preview,
//   unread +1 each), only to chats in the stored list (the same message then
//   arriving from the feed counts once: store_sync_seam_test);
// - chat: on the first paint the chat's push rows follow its stored rows,
//   oldest first; when the server row arrives the message is shown once.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/crypto/data/push_inbox_writer.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/drift_stores.dart';
import '../../support/fakes.dart';
import '../../support/store_spy.dart' show eventually;
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'me', displayName: 'Maya');
const _alice = Member(userId: 'alice', displayName: 'Alice');
const _carol = Member(userId: 'carol', displayName: 'Carol');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

final _t0 = DateTime.utc(2026, 3, 1, 9);

Conversation _conv(String id, Member other, String text, {int unread = 0}) =>
    Conversation(
      id: id,
      other: other,
      lastMessage: text,
      lastMessageAt: _t0,
      lastSenderId: other.userId,
      unread: unread,
    );

void main() {
  late StoreHarness h;
  late String key;
  late ChatFake chat;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    // The previous run: the list and one stored message are on the phone.
    final s = driftStore('me', h.dir, key);
    await DriftChatListSnapshotStore(s).save('me', [
      _conv('c1', _alice, 'stored text'),
      _conv('c2', _carol, 'carol old'),
    ]);
    await s.upsertAll([
      Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'alice',
        body: 'stored text',
        createdAt: _t0,
      ),
    ]);
    await s.close();
  });

  /// The notification saves [id] with the app closed (or not reading).
  void push(String id, String body, {String conv = 'c1', int minutes = 1}) {
    final code = writePushInbox(
      path: storeFileIn(h.dir).path,
      keyHex: key,
      conversationId: conv,
      messageId: id,
      peerUserId: conv == 'c1' ? 'alice' : 'carol',
      body: body,
      sealed: 'ab' * 32,
      receivedAtMicros: _t0
          .add(Duration(minutes: minutes))
          .microsecondsSinceEpoch,
      budgetMs: 3000,
    );
    expect(code, 'saved', reason: 'fixture: the push writer saved it');
  }

  /// The app after the session settled, as SessionGate mounts it.
  Future<ProviderContainer> app() async {
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        ...driftStoreOverrides(h.dir, key),
      ],
    );
    addTearDown(() => quit(c));
    c.listen(currentUserIdProvider, (_, _) {});
    await c.read(sessionControllerProvider.future);
    return c;
  }

  Future<List<Conversation>> cachedList(ProviderContainer c) async {
    chat.holdList();
    c.listen(conversationListProvider, (_, _) {});
    await eventually(
      () => c.read(conversationListProvider).value?.isNotEmpty ?? false,
      reason: 'the stored list before the server answers',
    );
    return c.read(conversationListProvider).value!;
  }

  Conversation byId(List<Conversation> l, String id) =>
      l.firstWhere((x) => x.id == id);

  group('chat list, first paint from the phone', () {
    test(
      'a push row is the preview and +1 unread; other chats unchanged',
      () async {
        push('n1', 'from the notification');
        final c = await app();
        final l = await cachedList(c);
        final c1 = byId(l, 'c1');
        expect(c1.lastMessage, 'from the notification');
        expect(c1.unread, 1);
        expect(byId(l, 'c2').lastMessage, 'carol old');
        expect(byId(l, 'c2').unread, 0);
        expect(l.first.id, 'c1', reason: 'newest chat on top');
        chat.releaseList();
      },
    );

    test('two push rows: the newest is the preview, unread +2', () async {
      push('n1', 'first', minutes: 1);
      push('n2', 'second', minutes: 2);
      final c = await app();
      final c1 = byId(await cachedList(c), 'c1');
      expect(c1.lastMessage, 'second');
      expect(c1.unread, 2);
      chat.releaseList();
    });

    test('without push rows the stored list is shown as saved', () async {
      final c = await app();
      final c1 = byId(await cachedList(c), 'c1');
      expect(c1.lastMessage, 'stored text');
      expect(c1.unread, 0);
      chat.releaseList();
    });
  });

  group('chat, first paint', () {
    Future<List<String>> firstPaint(ProviderContainer c, String conv) async {
      chat.holdMessages();
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open(conv);
      await eventually(
        () => c.read(messagesProvider).value?.isNotEmpty ?? false,
        reason: 'the first paint before the server answers',
      );
      return [for (final m in c.read(messagesProvider).value!) m.id];
    }

    test('the chat\'s push rows follow its stored rows, oldest first; other '
        'chats\' rows are not shown', () async {
      push('n2', 'second', minutes: 2);
      push('n1', 'first', minutes: 1);
      push('x1', 'carol push', conv: 'c2', minutes: 3);
      final c = await app();
      expect(await firstPaint(c, 'c1'), ['m1', 'n1', 'n2']);
      final n1 = c.read(messagesProvider).value![1];
      expect((n1.body, n1.senderId), ('first', 'alice'));
      chat.releaseMessages();
    });

    test('a chat with only a push row shows it', () async {
      push('x1', 'carol push', conv: 'c2');
      final c = await app();
      expect(await firstPaint(c, 'c2'), ['x1']);
      chat.releaseMessages();
    });

    test('the server page with the real row: the message is shown once, with '
        'the server text', () async {
      push('n1', 'push text');
      chat.history['c1'] = [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'alice',
          body: 'stored text',
          createdAt: _t0,
        ),
        Message(
          id: 'n1',
          conversationId: 'c1',
          senderId: 'alice',
          body: 'server text',
          createdAt: _t0.add(const Duration(seconds: 30)),
        ),
      ];
      final c = await app();
      expect(await firstPaint(c, 'c1'), ['m1', 'n1']);
      chat.releaseMessages();
      await eventually(
        () =>
            c
                .read(messagesProvider)
                .value
                ?.any((m) => m.id == 'n1' && m.body == 'server text') ??
            false,
        reason: 'server row shown',
      );
      final shown = [for (final m in c.read(messagesProvider).value!) m.id];
      expect(shown.where((id) => id == 'n1'), hasLength(1));
    });
  });
}
