// chatSelectionProvider and chatDeleteProvider against the shared fakes --
// never the SDK. Written from the contract (start / undo / consumeFailure,
// ChatDeleteState, the commit rules), not from how they are built.
//
// testWidgets for its fake clock: the 5 s undo window and the countdown are
// walked second by second.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_delete_controller.dart';
import 'package:sis/features/chat/application/chat_selection_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_member.dart';

import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/group_settings_fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob Stone');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class _Uid extends CurrentUserId {
  @override
  String? build() => 'u1';
  void set(String? v) => state = v;
}

// Newest first, as the server lists them.
final t0 = DateTime.utc(2026, 10, 7, 12);
final d1 = Conversation(id: 'd1', other: bob, lastMessageAt: t0);
final d2 = Conversation(
  id: 'd2',
  other: const Member(userId: 'u3', displayName: 'Cem'),
  lastMessageAt: t0.subtract(const Duration(minutes: 1)),
);
final g1 = Conversation(
  id: 'g1',
  title: 'Trip',
  lastMessageAt: t0.subtract(const Duration(minutes: 2)),
);
final admin = Conversation(
  id: 'ga',
  title: 'Club',
  isAdmin: true,
  lastMessageAt: t0.subtract(const Duration(minutes: 3)),
);
final left = Conversation(
  id: 'gl',
  title: 'Old',
  hasLeft: true,
  lastMessageAt: t0.subtract(const Duration(minutes: 4)),
);

typedef W = ({
  ProviderContainer c,
  ChatFake chat,
  ChatDeleteFake del,
  GroupSettingsFake groups,
});

/// Runs every microtask and zero timer, without moving the clock.
Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump();
  }
}

Future<W> start(
  WidgetTester t,
  List<Conversation> rows, {
  bool journal = false,
}) async {
  final chat = ChatFake(self: me.userId)..conversationsResult = Ok(rows);
  for (final r in rows.where((r) => r.isGroup && !r.hasLeft)) {
    chat.groupRosters[r.id] = [
      GroupMember(member: me, isAdmin: r.isAdmin),
      const GroupMember(member: bob, isAdmin: false),
    ];
  }
  void drop(String id) {
    if (chat.conversationsResult case Ok(value: final all)) {
      chat.conversationsResult = Ok([
        for (final c in all)
          if (c.id != id) c,
      ]);
    }
  }

  final del = ChatDeleteFake(
    chat: chat,
    journal: journal ? chat.groupWrites : null,
  );
  final groups = GroupSettingsFake(onDeleted: drop);
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      chatDeleteRepositoryProvider.overrideWithValue(del),
      groupSettingsRepositoryProvider.overrideWithValue(groups),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(conversationListProvider, (_, _) {});
  c.listen(chatDeleteProvider, (_, _) {});
  c.listen(chatSelectionProvider, (_, _) {});
  await hop(t);
  await t.pump(const Duration(milliseconds: 1));
  await hop(t);
  expect(ids(c), [for (final r in rows) r.id], reason: 'list not loaded');
  return (c: c, chat: chat, del: del, groups: groups);
}

List<String> ids(ProviderContainer c) => [
  for (final x in c.read(conversationListProvider).value ?? const []) x.id,
];

ChatDeleteState st(ProviderContainer c) => c.read(chatDeleteProvider);

/// Past the 5 s window, plus the server calls and the quiet reload.
Future<void> runOut(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(seconds: 1));
    await hop(t);
  }
  await t.pump(const Duration(milliseconds: 500));
  await hop(t);
}

/// Server writes, whichever repository took them.
List<String> writes(W w) => [
  ...w.del.calls,
  ...w.groups.calls.where((c) => c != 'subscribe'),
  ...w.chat.groupWrites,
];

void main() {
  group('chatSelectionProvider', () {
    test('toggle adds and removes, clear empties, a new user resets', () {
      final c = ProviderContainer.test(
        overrides: [currentUserIdProvider.overrideWith(_Uid.new)],
      );
      c.listen(chatSelectionProvider, (_, _) {});
      final sel = c.read(chatSelectionProvider.notifier);
      sel.toggle('a');
      sel.toggle('b');
      expect(c.read(chatSelectionProvider), {'a', 'b'});
      sel.toggle('a');
      expect(c.read(chatSelectionProvider), {'b'});
      sel.clear();
      expect(c.read(chatSelectionProvider), isEmpty);

      sel.toggle('a');
      (c.read(currentUserIdProvider.notifier) as _Uid).set('u9');
      expect(c.read(chatSelectionProvider), isEmpty);
    });
  });

  group('chatDeleteProvider', () {
    testWidgets('start hides the rows at once and clears the selection', (
      t,
    ) async {
      final w = await start(t, [d1, d2, g1]);
      w.c.read(chatSelectionProvider.notifier).toggle('d2');
      w.c.read(chatDeleteProvider.notifier).start([d2], alsoForOthers: false);
      expect(ids(w.c), ['d1', 'g1'], reason: 'not hidden synchronously');
      expect(w.c.read(chatSelectionProvider), isEmpty);
      expect(writes(w), isEmpty, reason: 'a server call inside the window');
      await runOut(t);
    });

    for (final (name, chats, also, notice) in [
      ('one 1:1', [d1], false, ChatDeleteNotice.chat),
      ('one 1:1 for both', [d1], true, ChatDeleteNotice.chat),
      ('two chats', [d1, d2], false, ChatDeleteNotice.chats),
      ('a group, not admin', [g1], false, ChatDeleteNotice.groupLeft),
      ('an admin group, ticked', [admin], true, ChatDeleteNotice.groupDeleted),
      ('an admin group, unticked', [admin], false, ChatDeleteNotice.groupLeft),
    ]) {
      testWidgets('notice for $name is ${notice.name}', (t) async {
        final w = await start(t, [d1, d2, g1, admin]);
        w.c.read(chatDeleteProvider.notifier).start(chats, alsoForOthers: also);
        expect(st(w.c).notice, notice);
        await runOut(t);
      });
    }

    testWidgets('secondsLeft is 5 at start and counts down to 1', (t) async {
      final w = await start(t, [d1]);
      w.c.read(chatDeleteProvider.notifier).start([d1], alsoForOthers: false);
      expect(st(w.c).secondsLeft, 5);
      for (final n in [4, 3, 2, 1]) {
        await t.pump(const Duration(seconds: 1));
        expect(st(w.c).secondsLeft, n);
      }
      await runOut(t);
      expect(st(w.c).notice, isNull, reason: 'the bar outlived its window');
    });

    testWidgets('undo puts the rows back in order and asks the server '
        'nothing', (t) async {
      final w = await start(t, [d1, d2, g1, admin]);
      w.c.read(chatDeleteProvider.notifier).start([
        d2,
        admin,
      ], alsoForOthers: true);
      expect(ids(w.c), ['d1', 'g1']);
      await t.pump(const Duration(seconds: 3));
      w.c.read(chatDeleteProvider.notifier).undo();
      expect(ids(w.c), ['d1', 'd2', 'g1', 'ga']);
      expect(st(w.c).notice, isNull);
      await runOut(t);
      await runOut(t);
      expect(writes(w), isEmpty);
      expect(ids(w.c), ['d1', 'd2', 'g1', 'ga']);
    });

    for (final (name, chats, also, expected) in [
      ('a 1:1, ticked', [d1], true, ['deleteDirect:d1']),
      ('a 1:1, unticked', [d1], false, ['hide:d1']),
      ('the one admin group, ticked', [admin], true, ['delete:ga']),
      (
        'the one admin group, unticked',
        [admin],
        false,
        ['hide:ga', 'leave:ga'],
      ),
      ('a group, not admin', [g1], true, ['hide:g1', 'leave:g1']),
      ('a group already left', [left], false, ['hide:gl']),
      (
        'two chats with an admin group, ticked',
        [d1, admin],
        true,
        ['deleteDirect:d1', 'hide:ga', 'leave:ga'],
      ),
    ]) {
      testWidgets('at 0 s $name commits ${expected.join(', ')}', (t) async {
        final w = await start(t, [d1, g1, admin, left]);
        w.c.read(chatDeleteProvider.notifier).start(chats, alsoForOthers: also);
        await t.pump(const Duration(milliseconds: 4900));
        expect(writes(w), isEmpty, reason: 'committed before 5 s');
        await runOut(t);
        expect(writes(w)..sort(), [...expected]..sort());
        for (final c in chats) {
          expect(ids(w.c), isNot(contains(c.id)), reason: 'back after reload');
        }
        expect(st(w.c).failure, isNull);
      });
    }

    testWidgets('a group is left before it is hidden', (t) async {
      final w = await start(t, [g1], journal: true);
      w.c.read(chatDeleteProvider.notifier).start([g1], alsoForOthers: false);
      await runOut(t);
      expect(w.chat.groupWrites, ['leave:g1', 'hide:g1']);
    });

    testWidgets('a refused leave is reported and the group is not hidden', (
      t,
    ) async {
      final w = await start(t, [d1, g1]);
      w.chat.leaveResult = const Err(NetworkFailure('offline'));
      w.c.read(chatDeleteProvider.notifier).start([g1], alsoForOthers: false);
      await runOut(t);
      expect(w.del.calls, isEmpty, reason: 'hidden although still a member');
      expect(st(w.c).failure, isA<NetworkFailure>());
      expect(ids(w.c), ['d1', 'g1']);
    });

    testWidgets('a new delete commits the pending one at once', (t) async {
      final w = await start(t, [d1, d2]);
      final n = w.c.read(chatDeleteProvider.notifier);
      n.start([d1], alsoForOthers: false);
      await t.pump(const Duration(seconds: 2));
      n.start([d2], alsoForOthers: true);
      await t.pump(const Duration(milliseconds: 200));
      await hop(t);
      expect(w.del.calls, ['hide:d1'], reason: 'first not committed early');
      expect(st(w.c).notice, ChatDeleteNotice.chat);
      expect(st(w.c).secondsLeft, 5);
      await runOut(t);
      expect(w.del.calls, ['hide:d1', 'deleteDirect:d2']);
    });

    testWidgets('a refusal reports a failure and the row comes back', (
      t,
    ) async {
      final w = await start(t, [d1, d2]);
      w.del.hideResult = const Err(NetworkFailure('offline'));
      w.c.read(chatDeleteProvider.notifier).start([d1], alsoForOthers: false);
      expect(ids(w.c), ['d2']);
      await runOut(t);
      expect(w.del.calls, ['hide:d1']);
      expect(st(w.c).failure, isA<NetworkFailure>());
      expect(ids(w.c), ['d1', 'd2']);
      w.c.read(chatDeleteProvider.notifier).consumeFailure();
      expect(st(w.c).failure, isNull);
    });
  });
}
