// Read status across a background (0.30.5), from the contract only:
//
// - resumeCatchUpProvider, session Allowed, chat X open: markRead(X) exactly
//   once; readMarksProvider rebuilt (readUpdates(X) and readMarks(X) again);
//   the list catch-up (incomingAll + list re-read) after markRead has
//   completed; the messages catch-up and clearConversation(X) as before.
//   No chat open: only the list catch-up. Not Allowed: nothing.
// - appVisibleProvider (default true): a live message from the other member
//   is marked read only while visible; my own message never is.
// - markRead failing does not throw or block the list; a failed re-join of
//   reads:<id> still loads the marks; a resume during a marks load does not
//   duplicate; a member not sharing keeps seeing no marks.
//
// The defect (owner, TestFlight): iOS suspends the socket at once and
// Realtime replays nothing, so a read broadcast sent while the sender was
// away was never heard, and messages the reader's catch-up loaded were never
// marked read. ChatFake models both: loseRealtime() kills message channels;
// a read mark not delivered with deliverRead() is simply gone.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const maya = Member(userId: 'u1', displayName: 'Maya');
final _t0 = DateTime.utc(2026, 9, 29, 12);
final _t1 = _t0.add(const Duration(minutes: 5));

Message msg(String id, int minute, {String conv = 'c1', String from = 'u2'}) =>
    Message(
      id: id,
      conversationId: conv,
      senderId: from,
      body: 'body $id',
      createdAt: _t0.add(Duration(minutes: minute)),
    );

Conversation conv(String id, {int unread = 0, String title = 'Bob'}) =>
    Conversation(
      id: id,
      title: title,
      lastMessage: 'body m1',
      lastMessageAt: _t0.add(const Duration(minutes: 1)),
      lastSenderId: 'u2',
      unread: unread,
    );

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(maya);
}

class _Out extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
}

OwnProfile _profile({bool share = true}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  shareReadStatus: share,
);

Future<void> eventually(
  bool Function() ok, {
  Duration within = const Duration(seconds: 2),
  String reason = '',
}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('never happened: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late ChatFake chat;
  late PushSourceFake push;
  late ProfileFake profiles;
  late ProviderContainer c;

  Future<void> make({bool allowed = true}) async {
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        pushSourceProvider.overrideWithValue(push),
        profileRepositoryProvider.overrideWithValue(profiles),
        sessionControllerProvider.overrideWith(allowed ? _In.new : _Out.new),
      ],
    );
    await c.read(sessionControllerProvider.future);
    if (allowed) {
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);
    }
  }

  int count(String call, [int from = 0]) =>
      chat.calls.sublist(from).where((x) => x == call).length;
  Conversation row(String id) => c
      .read(conversationListProvider)
      .requireValue
      .singleWhere((r) => r.id == id);
  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  ReadMark? markOf(String userId) => c
      .read(readMarksProvider)
      .value
      ?.where((m) => m.userId == userId)
      .firstOrNull;

  Future<void> loadList() async {
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    chat.confirmAllSubscription();
    await settle(20);
  }

  /// Opens [id] the way the message screen does: messages and read marks
  /// both watched.
  Future<void> open(String id) async {
    c.listen(messagesProvider, (_, _) {});
    c.listen(readMarksProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(id);
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
    await c.read(readMarksProvider.future);
    await settle(20);
  }

  /// The list's catch-up (read, join, read again) ran to its end.
  Future<void> listCaughtUp(int mark) async {
    await eventually(
      () => count('conversations', mark) >= 2,
      reason: 'the list re-read twice',
    );
    await settle(30);
  }

  setUp(() {
    chat = ChatFake(self: 'u1', latency: const Duration(milliseconds: 2));
    push = PushSourceFake();
    profiles = ProfileFake(profile: _profile());
    chat.history['c1'] = [msg('m1', 1)];
    chat.conversationsResult = Ok([conv('c1'), conv('c2', title: 'Cy')]);
    chat.readMarksData['c1'] = [
      ReadMark(userId: 'u2', shares: true, readAt: _t0),
    ];
  });

  group('resume with a chat open', () {
    setUp(() async {
      await make();
      await loadList();
      await open('c1');
    });

    test('marks it read exactly once, re-joins and re-reads the read marks, '
        'catches the chat and the list up, clears its notification', () async {
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      final mark = chat.calls.length;
      final marked = chat.markedRead.length;

      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);
      await eventually(() => shown().contains('m2'), reason: 'the chat');

      expect(chat.markedRead.sublist(marked), ['c1'], reason: 'markRead(X)');
      expect(count('readUpdates:c1', mark), 1, reason: 'reads re-joined');
      expect(count('readMarks:c1', mark), 1, reason: 'reads re-read');
      expect(count('incomingAll', mark), 1, reason: 'list re-joined');
      expect(push.cleared, ['c1']);
    });

    test('a read mark whose broadcast was lost while away shows after '
        'resume', () async {
      expect(markOf('u2')?.readAt, _t0, reason: 'fixture');
      // Bob read while Maya was backgrounded; the reads:c1 broadcast went
      // to a dead socket. Only the server's row knows.
      chat.readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: _t1),
      ];
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);
      await c.read(readMarksProvider.future);

      expect(markOf('u2')?.readAt, _t1, reason: 'stale until reopened');
    });

    test('the live read channel works again after resume', () async {
      final mark = chat.calls.length;
      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);
      await c.read(readMarksProvider.future);

      chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: _t1));
      await settle();
      expect(markOf('u2')?.readAt, _t1);
    });

    test('the markRead completes before the list re-reads, so the list '
        'shows the chat as read', () async {
      chat.loseRealtime();
      chat.deliver(msg('m2', 2)); // the server now counts c1 unread 1
      chat.holdMarkRead();
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();
      await eventually(() => chat.markedRead.isNotEmpty, reason: 'markRead');
      await settle(60);
      expect(
        count('conversations', mark),
        lessThan(2),
        reason: 'the list finished its catch-up while markRead was in flight',
      );

      chat.releaseMarkRead();
      await listCaughtUp(mark);
      expect(row('c1').lastMessage, 'body m2');
      expect(row('c1').unread, 0, reason: 'list re-read before the read');
    });

    test('markRead failing neither throws nor blocks the list', () async {
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      chat.markReadResult = const Err(NetworkFailure('offline'));
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);

      expect(chat.markedRead, contains('c1'));
      expect(c.read(conversationListProvider).hasError, isFalse);
      expect(row('c1').lastMessage, 'body m2', reason: 'list not re-read');
      expect(shown(), contains('m2'));
    });

    test('a failed re-join of reads:<id> still loads the marks', () async {
      chat.readUpdatesResult = const Err(NetworkFailure('realtime down'));
      chat.readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: _t1),
      ];
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);
      final marks = await c.read(readMarksProvider.future);

      expect(count('readUpdates:c1', mark), 1);
      expect(marks.single.readAt, _t1);
    });

    test('a message that arrives only in the post-resume load is marked '
        'read', () async {
      // Socket dead while away: m2 is in the database, never live here.
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      await settle();
      expect(shown(), ['m1'], reason: 'fixture: m2 not live');
      final marked = chat.markedRead.length;
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);

      expect(shown(), contains('m2'));
      expect(chat.markedRead.sublist(marked), ['c1']);
    });
  });

  test('resume while the read marks are still loading: no duplicate '
      'marks', () async {
    await make();
    await loadList();
    chat.readMarksData['c1'] = [
      ReadMark(userId: 'u2', shares: true, readAt: _t0),
      const ReadMark(userId: 'u3', shares: true),
    ];
    chat.holdReadMarks();
    c.listen(messagesProvider, (_, _) {});
    c.listen(readMarksProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
    await eventually(() => chat.readMarksCalls.isNotEmpty);
    final mark = chat.calls.length;

    c.read(resumeCatchUpProvider)();
    await settle();
    chat.releaseReadMarks();
    await listCaughtUp(mark);
    chat.releaseReadMarks();
    await settle();
    final marks = await c.read(readMarksProvider.future);

    expect(marks.map((m) => m.userId).toList()..sort(), ['u2', 'u3']);
    expect(
      chat.readSubscriptions - chat.canceledReadSubscriptions,
      1,
      reason: 'more than one live reads:c1 subscription left',
    );
  });

  test('a member not sharing read status sees no marks after resume', () async {
    profiles = ProfileFake(profile: _profile(share: false));
    // Mutual: the server shares nothing with a member who does not share.
    chat.readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
    await make();
    await loadList();
    await open('c1');
    final mark = chat.calls.length;

    c.read(resumeCatchUpProvider)();
    await listCaughtUp(mark);
    final marks = await c.read(readMarksProvider.future);

    expect(marks.where((m) => m.shares || m.readAt != null), isEmpty);
  });

  test('a group: "read by" updates after resume', () async {
    chat.history['g1'] = [msg('g-m1', 1, conv: 'g1')];
    chat.conversationsResult = Ok([conv('g1', title: 'Team'), conv('c1')]);
    chat.readMarksData['g1'] = [
      ReadMark(userId: 'u2', shares: true, readAt: _t0),
      const ReadMark(userId: 'u3', shares: true),
    ];
    await make();
    await loadList();
    await open('g1');
    chat.readMarksData['g1'] = [
      ReadMark(userId: 'u2', shares: true, readAt: _t1),
      ReadMark(userId: 'u3', shares: true, readAt: _t1),
    ];
    final mark = chat.calls.length;
    final marked = chat.markedRead.length;

    c.read(resumeCatchUpProvider)();
    await listCaughtUp(mark);
    await c.read(readMarksProvider.future);

    expect(markOf('u2')?.readAt, _t1);
    expect(markOf('u3')?.readAt, _t1);
    expect(chat.markedRead.sublist(marked), ['g1']);
  });

  test('no chat open: only the list catches up', () async {
    await make();
    await loadList();
    chat.loseRealtime();
    chat.deliver(msg('m2', 2));
    final mark = chat.calls.length;

    c.read(resumeCatchUpProvider)();
    await listCaughtUp(mark);

    expect(row('c1').lastMessage, 'body m2');
    expect(chat.markedRead, isEmpty);
    expect(
      chat.calls.sublist(mark).where((x) => x.startsWith('readUpdates')),
      isEmpty,
    );
    expect(
      chat.calls.sublist(mark).where((x) => x.startsWith('readMarks')),
      isEmpty,
    );
  });

  test('session not allowed: resume does nothing', () async {
    await make(allowed: false);
    c.read(openConversationProvider.notifier).open('c1');
    final mark = chat.calls.length;

    c.read(resumeCatchUpProvider)();
    await settle(80);

    expect(chat.calls.sublist(mark), isEmpty);
    expect(chat.markedRead, isEmpty);
  });

  group('live messages and appVisible', () {
    setUp(() async {
      await make();
      await loadList();
      await open('c1');
    });

    test('defaults to visible', () {
      expect(c.read(appVisibleProvider), isTrue);
    });

    test(
      "visible: the other member's live message is marked read once",
      () async {
        final marked = chat.markedRead.length;
        chat.deliver(msg('m2', 2));
        await eventually(() => shown().contains('m2'));
        await settle();
        expect(chat.markedRead.sublist(marked), ['c1']);
      },
    );

    test('hidden: a live message is not marked read; on return it is, '
        'exactly once, and the message is in the list', () async {
      final marked = chat.markedRead.length;
      c.read(appVisibleProvider.notifier).set(false);
      chat.deliver(msg('m2', 2));
      await eventually(() => shown().contains('m2'));
      await settle();
      expect(
        chat.markedRead.sublist(marked),
        isEmpty,
        reason: 'marked read while nobody saw it',
      );

      final mark = chat.calls.length;
      c.read(appVisibleProvider.notifier).set(true);
      c.read(resumeCatchUpProvider)();
      await listCaughtUp(mark);

      expect(chat.markedRead.sublist(marked), ['c1']);
      expect(row('c1').lastMessage, 'body m2');
      expect(shown(), contains('m2'));
    });

    test('my own live message never triggers markRead', () async {
      final marked = chat.markedRead.length;
      chat.deliver(msg('m2', 2, from: 'u1'));
      await eventually(() => shown().contains('m2'));
      await settle();
      expect(chat.markedRead.sublist(marked), isEmpty);
    });
  });
}
