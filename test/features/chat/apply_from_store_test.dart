// ConversationListController.applyFromStore <-> REAL encrypted store and
// snapshot store <-> ChatFake. From the slice-1 contract only:
// a newer row from another sender adds 1 unread, moves the chat to the top
// and sets the preview; the same row twice or an older row changes nothing;
// an own row adds no unread; deleted, edited and unknown-chat rows are
// ignored; before the list has loaded nothing happens.
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
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'me', displayName: 'Maya');
const _deniz = Member(userId: 'u1', displayName: 'Deniz');
const _ece = Member(userId: 'u2', displayName: 'Ece');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

/// Server list order: c1 (newest, 2 unread), then c2.
final _server = [
  Conversation(
    id: 'c1',
    other: _deniz,
    lastMessage: 'one',
    lastMessageAt: at(10),
    lastSenderId: 'u1',
    unread: 2,
  ),
  Conversation(
    id: 'c2',
    other: _ece,
    lastMessage: 'two',
    lastMessageAt: at(5),
    lastSenderId: 'u2',
  ),
];

void main() {
  late StoreHarness h;
  late DriftMessageStore real;
  late ChatFake chat;
  late ProviderContainer c;

  setUp(() async {
    h = await StoreHarness.create();
    real = h.open(owner: 'me', key: await h.newKey());
    addTearDown(real.close);
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    chat.conversationsResult = Ok(_server);
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        messageStoreProvider.overrideWithValue(SpyStore(real)),
        chatListSnapshotStoreProvider.overrideWithValue(
          DriftChatListSnapshotStore(real),
        ),
      ],
    );
  });

  List<Conversation> now() => c.read(conversationListProvider).value!;

  Future<void> load() async {
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    await eventually(() {
      final s = c.read(conversationListProvider);
      return s.hasValue && !s.isLoading && s.value!.length == 2;
    }, reason: 'server list loaded');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect([for (final x in now()) x.unread], [2, 0], reason: 'baseline');
  }

  ConversationListController list() =>
      c.read(conversationListProvider.notifier);

  List<(String, int, String?, DateTime?)> summary() => [
    for (final x in now()) (x.id, x.unread, x.lastMessage, x.lastMessageAt),
  ];

  test('a newer row from another sender: +1 unread, to the top, preview '
      'set', () async {
    await load();
    list().applyFromStore([msg('m1', conv: 'c2', t: 20, body: 'new')]);
    final after = now();
    expect(after[0].id, 'c2', reason: 'moved to the top');
    expect(after[0].unread, 1);
    expect(after[0].lastMessage, 'new');
    expect(after[0].lastMessageAt, at(20));
    expect(after[0].lastSenderId, 'u1');
    expect(after[1].id, 'c1');
    expect(after[1].unread, 2, reason: 'other chat untouched');
  });

  test('the same row twice counts once', () async {
    await load();
    final m = msg('m1', conv: 'c1', t: 20, body: 'new');
    list().applyFromStore([m]);
    list().applyFromStore([m]);
    list().applyFromStore([m, m]);
    expect(now().firstWhere((x) => x.id == 'c1').unread, 3);
  });

  test('an older row changes nothing', () async {
    await load();
    final before = summary();
    list().applyFromStore([msg('m2', conv: 'c2', t: 1, body: 'old')]);
    expect(summary(), before);
  });

  test('a row from the member adds no unread', () async {
    await load();
    list().applyFromStore([
      msg('m3', conv: 'c2', t: 15, body: 'mine', sender: 'me'),
    ]);
    expect(now().firstWhere((x) => x.id == 'c2').unread, 0);
  });

  test('a deleted row is ignored', () async {
    await load();
    final before = summary();
    list().applyFromStore([
      msg('m4', conv: 'c2', t: 15, deletion: MessageDeletion.placeholder),
    ]);
    expect(summary(), before);
  });

  test('an edited row is ignored', () async {
    await load();
    final before = summary();
    list().applyFromStore([
      Message(
        id: 'm5',
        conversationId: 'c2',
        senderId: 'u1',
        body: 'edit',
        createdAt: at(15),
        editedAt: at(50),
      ),
    ]);
    expect(summary(), before);
  });

  test('a row of an unknown chat is ignored', () async {
    await load();
    final before = summary();
    list().applyFromStore([msg('m6', conv: 'cx', t: 20, body: 'new')]);
    expect(summary(), before);
  });

  test('before the list has loaded nothing happens', () async {
    c.listen(conversationListProvider, (_, _) {});
    list().applyFromStore([msg('m1', conv: 'c2', t: 20, body: 'new')]);
    await load();
    expect(summary(), [('c1', 2, 'one', at(10)), ('c2', 0, 'two', at(5))]);
  });
}
