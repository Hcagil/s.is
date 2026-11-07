// Seam: ConversationListController.build -> the stored list + the push inbox
// in ONE store call (slice 1, t_f79a5084b0). Written from the contract,
// never from the implementation:
// - a snapshot store that is a ChatListWithPushStore: loadWithPush once, its
//   push rows are used, no separate pushInbox read, load() not called;
// - a store that is only a ChatListSnapshotStore: load() + pushInbox() as
//   before.
// The message store is the REAL encrypted DriftMessageStore (as main.dart
// wires it); the snapshot store is the REAL DriftChatListSnapshotStore behind
// a logging decorator. The decorator of the one-read path swaps the push rows
// for its own, so which read fed the list is visible in the preview.
// StartupMarks logs once per process: the mark test is FIRST.
import 'package:flutter/foundation.dart' show debugPrint, DebugPrintCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/chat_list_snapshot_store.dart';
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

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

final _t0 = DateTime.utc(2026, 3, 1, 9);

/// Only the old interface: load / save / clear, logged.
class _OnlyLoad implements ChatListSnapshotStore {
  _OnlyLoad(this.inner, this.log);
  final DriftChatListSnapshotStore inner;
  final List<String> log;

  @override
  Future<List<Conversation>?> load(String ownerId) {
    log.add('load');
    return inner.load(ownerId);
  }

  @override
  Future<void> save(String ownerId, List<Conversation> c) =>
      inner.save(ownerId, c);

  @override
  Future<void> clear() => inner.clear();
}

/// Both interfaces; loadWithPush returns the real list with [push] as its
/// push rows (instead of what the file holds).
class _OneRead extends _OnlyLoad implements ChatListWithPushStore {
  _OneRead(super.inner, super.log, this.push);
  final List<Message> push;

  @override
  Future<({List<Conversation> list, List<Message> push})?> loadWithPush(
    String ownerId,
  ) async {
    log.add('loadWithPush');
    final real = await inner.loadWithPush(ownerId);
    return real == null ? null : (list: real.list, push: push);
  }
}

void main() {
  late StoreHarness h;
  late String key;
  late ChatFake chat;
  late List<String> log;

  final oneReadRow = Message(
    id: 'n-one',
    conversationId: 'c1',
    senderId: 'alice',
    body: 'from one read',
    createdAt: _t0.add(const Duration(minutes: 2)),
  );

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    log = [];
    final s = driftStore('me', h.dir, key);
    await DriftChatListSnapshotStore(s).save('me', [
      Conversation(
        id: 'c1',
        other: _alice,
        lastMessage: 'stored text',
        lastMessageAt: _t0,
        lastSenderId: 'alice',
      ),
    ]);
    await s.close();
    final code = writePushInbox(
      path: storeFileIn(h.dir).path,
      keyHex: key,
      conversationId: 'c1',
      messageId: 'n-disk',
      peerUserId: 'alice',
      body: 'from disk inbox',
      sealed: 'ab' * 32,
      receivedAtMicros: _t0
          .add(const Duration(minutes: 1))
          .microsecondsSinceEpoch,
      budgetMs: 3000,
    );
    expect(code, 'saved', reason: 'fixture: the push writer saved it');
  });

  Future<Conversation> firstPaint(
    ChatListSnapshotStore Function(DriftChatListSnapshotStore) wrap,
  ) async {
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        driftStoreOverrides(h.dir, key).first, // messageStoreProvider
        chatListSnapshotStoreProvider.overrideWith(
          (ref) => wrap(
            DriftChatListSnapshotStore(
              ref.watch(messageStoreProvider) as DriftMessageStore,
            ),
          ),
        ),
      ],
    );
    addTearDown(() => quit(c));
    c.listen(currentUserIdProvider, (_, _) {});
    await c.read(sessionControllerProvider.future);
    chat.holdList();
    addTearDown(chat.releaseList);
    c.listen(conversationListProvider, (_, _) {});
    await eventually(
      () => c.read(conversationListProvider).value?.isNotEmpty ?? false,
      reason: 'the stored list before the server answers',
    );
    return c.read(conversationListProvider).value!.single;
  }

  test('mark list-cached once on the stored first paint', () async {
    final lines = <String>[];
    final DebugPrintCallback saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) lines.add(m);
    };
    addTearDown(() => debugPrint = saved);
    await firstPaint((s) => _OneRead(s, log, [oneReadRow]));
    expect(
      lines.where((l) => l.startsWith('sis.startup list-cached ')),
      hasLength(1),
    );
  });

  test('a ChatListWithPushStore: one loadWithPush, its push rows, no '
      'separate inbox read', () async {
    final c1 = await firstPaint((s) => _OneRead(s, log, [oneReadRow]));
    expect(log, ['loadWithPush']);
    expect(c1.lastMessage, 'from one read');
    expect(c1.unread, 1, reason: 'the disk inbox row was not read again');
  });

  test(
    'a ChatListWithPushStore with no push rows: the list as saved',
    () async {
      final c1 = await firstPaint((s) => _OneRead(s, log, const []));
      expect(log, ['loadWithPush']);
      expect(c1.lastMessage, 'stored text');
      expect(c1.unread, 0);
    },
  );

  test('only a ChatListSnapshotStore: load() and the inbox read', () async {
    final c1 = await firstPaint((s) => _OnlyLoad(s, log));
    expect(log, ['load']);
    expect(c1.lastMessage, 'from disk inbox');
    expect(c1.unread, 1);
  });
}
