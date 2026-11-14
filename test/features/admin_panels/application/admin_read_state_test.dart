import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_models.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;

  AdminPanelsState st() => c.read(adminPanelsProvider);

  Future<void> openIt() => ctrl.open('reason');

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  // Helper to create a conversation item
  AdminItem convItem({int seen = 0, int mat = 0, bool unread = false}) =>
      AdminItem(
        id: 'c:c1',
        kind: 'talk',
        seq: 1,
        removed: false,
        fields: {
          'id': 'c1',
          'topic': 'T',
          'at': 1000,
          'unread': unread,
          'waiting': 0,
          'conv': true,
          'seen': seen,
          'mat': mat,
        },
      );

  test('isUnread table', () {
    final conv1 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: true,
      waiting: 0,
      seen: 0,
      mat: 0,
    );
    expect(conv1.isUnread(999), isTrue);

    final conv2 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 0,
      mat: 0,
    );
    expect(conv2.isUnread(0), isFalse);

    final conv3 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 10,
      mat: 20,
    );
    expect(conv3.isUnread(0), isTrue);
    expect(conv3.isUnread(15), isTrue);
    expect(conv3.isUnread(20), isFalse);

    final conv4 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 30,
      mat: 20,
    );
    expect(conv4.isUnread(0), isFalse);

    final conv5 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 0,
      mat: 20,
    );
    expect(conv5.isUnread(0), isTrue);
    expect(conv5.isUnread(20), isFalse);
  });

  test('payload', () async {
    final conv = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 0,
      mat: 20,
    );
    final r = await ctrl.markConversationRead(conv, 20);
    expect(r, isNull);
    expect(repo.sent.length, 1);
    final sent = repo.sent.first;
    expect(sent.keys.toList()..sort(), ['answer_id', 'conv', 'kind', 'upto']);
    expect(sent['kind'], 'read');
    expect(sent['conv'], 'c1');
    expect(sent['upto'], 20);
    expect(st().readUpto, {'c1': 20});
  });

  test('guard', () async {
    final convSeen20 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 20,
      mat: 20,
    );
    expect(await ctrl.markConversationRead(convSeen20, 20), isNull);
    expect(await ctrl.markConversationRead(convSeen20, 10), isNull);
    expect(repo.sent, isEmpty);
    expect(st().readUpto, isEmpty);

    final convSeen0 = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 0,
      mat: 20,
    );
    expect(await ctrl.markConversationRead(convSeen0, 20), isNull);
    expect(await ctrl.markConversationRead(convSeen0, 20), isNull);
    expect(repo.sent.length, 1);
    expect(await ctrl.markConversationRead(convSeen0, 25), isNull);
    expect(repo.sent.length, 2);
    expect(repo.sent.last['upto'], 25);
  });

  test('failed send', () async {
    repo.sendResult = Err<AdminSentRef?>(const NetworkFailure('boom'));
    final conv = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 0,
      mat: 20,
    );
    final r = await ctrl.markConversationRead(conv, 20);
    expect(r, isA<NetworkFailure>());
    expect(st().readUpto['c1'], 20);
    expect(repo.sent.length, 1);
    final r2 = await ctrl.markConversationRead(conv, 20);
    expect(r2, isNull);
    expect(repo.sent.length, 1);
    final r3 = await ctrl.markConversationRead(conv, 30);
    expect(r3, isA<NetworkFailure>());
    expect(repo.sent.length, 2);
    expect(repo.sent.last['upto'], 30);
  });

  test('no waiting card', () async {
    final conv = AdminConversation(
      id: 'c1',
      topic: 'T',
      at: 1000,
      unread: false,
      waiting: 0,
      seen: 0,
      mat: 20,
    );
    await ctrl.markConversationRead(conv, 20);
    expect(st().answers, isEmpty);
    expect(st().latestAnswer('talk', id: 'c1'), isNull);
    await ctrl.sendTalk('hi', conv: 'c1');
    final a = st().latestAnswer('talk', id: 'c1');
    expect(a, isNotNull);
    await ctrl.markConversationRead(conv, 50);
    expect(st().latestAnswer('talk', id: 'c1'), same(a));
    expect(st().answers.length, 1);
  });

  test('snapshot-driven', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [convItem(mat: 20)]),
      ],
      [
        deltaRow(2, 2, cursor: 6, items: [convItem(mat: 40)]),
      ],
    ];
    await openIt();
    final conv = st().snapshot.conversations.first;
    await ctrl.markConversationRead(conv, 20);
    expect(conv.isUnread(st().readUpto['c1']!), isFalse);
    await ctrl.refresh();
    expect(
      st().snapshot.conversations.first.isUnread(st().readUpto['c1']!),
      isTrue,
    );
    expect(repo.sent.length, 1);
  });

  test('read on the computer', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [convItem(mat: 20)]),
      ],
      [
        deltaRow(2, 2, cursor: 6, items: [convItem(seen: 40, mat: 40)]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    final conv = st().snapshot.conversations.first;
    expect(conv.isUnread(0), isFalse);
    expect(repo.sent, isEmpty);
  });
}
