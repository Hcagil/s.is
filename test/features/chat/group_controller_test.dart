// GroupController, leftConversationGuardProvider, SendQueueController
// .dropForLeft and chatTimelineProvider (v0.23.0: leaving a group, removing
// members, admins), against the shared fakes -- never the SDK. Written from
// the contract in docs/DECISIONS.md (2026-09-29) and the providers' own
// signatures, not from how they are built.
//
// testWidgets for its fake clock: "a dropped message is never retried" is
// only shown by letting every retry fall due and seeing nothing asked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/group_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/timeline.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');
const dee = Member(userId: 'u4', displayName: 'Dee');
const offline = NetworkFailure('No connection', retryable: true);

final t0 = DateTime.utc(2026, 9, 29, 10);

/// Runs every microtask and zero timer, without moving the clock.
Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump();
  }
}

/// Two groups, g1 (the caller an admin, with Bob and Cem) and g2.
HeldSendChat groups() => HeldSendChat()
  ..conversationsResult = const Ok([
    Conversation(id: 'g1', title: 'Trip'),
    Conversation(id: 'g2', title: 'Club'),
  ])
  ..groupRosters['g1'] = [
    const GroupMember(member: me, isAdmin: true),
    const GroupMember(member: bob, isAdmin: false),
    const GroupMember(member: cem, isAdmin: false),
  ]
  ..reachable.addAll([bob, cem, dee]);

Future<ProviderContainer> start(WidgetTester t, ChatFake chat) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  c.listen(conversationListProvider, (_, _) {});
  await hop(t);
  await t.pump(const Duration(milliseconds: 1));
  expect(c.read(sessionControllerProvider).value, isA<Allowed>());
  return c;
}

/// The same container, for tests on the real clock: providers that are
/// invalidated rebuild on the real event loop, not the test's fake one.
Future<ProviderContainer> startReal(ChatFake chat) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  await settled(c);
  c.listen(sendQueueProvider, (_, _) {});
  c.listen(conversationListProvider, (_, _) {});
  await c.read(conversationListProvider.future);
  return c;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

List<String> queued(ProviderContainer c, String conv) => [
  for (final m in c.read(sendQueueProvider)[conv] ?? const <Message>[]) m.id,
];

int asksFor(HeldSendChat chat, String conv) =>
    chat.asked.where((a) => a.conversationId == conv).length;

/// Queues [bodies] in [conv] and fails the first ask offline, so they wait
/// on a retry -- the state a member is in who typed while offline.
Future<void> queueOffline(
  WidgetTester t,
  ProviderContainer c,
  HeldSendChat chat,
  String conv,
  List<String> bodies,
) async {
  final q = c.read(sendQueueProvider.notifier);
  for (final b in bodies) {
    q.enqueue(conv, body: b);
  }
  await hop(t);
  final i = chat.asked.lastIndexWhere((a) => a.conversationId == conv);
  chat.fail(i, offline);
  await hop(t);
  expect(queued(c, conv), hasLength(bodies.length), reason: 'fixture');
}

Conversation? inList(ProviderContainer c, String id) => c
    .read(conversationListProvider)
    .value
    ?.where((x) => x.id == id)
    .firstOrNull;

void main() {
  group('SendQueueController.dropForLeft', () {
    testWidgets('drops a chat\'s queue and cancels its retry; another chat '
        'keeps both', (t) async {
      final chat = groups();
      final c = await start(t, chat);
      await queueOffline(t, c, chat, 'g1', ['a', 'b']);
      await queueOffline(t, c, chat, 'g2', ['x']);

      expect(c.read(sendQueueProvider.notifier).dropForLeft('g1'), isTrue);
      expect(queued(c, 'g1'), isEmpty);
      expect(queued(c, 'g2'), hasLength(1));

      final g1Before = asksFor(chat, 'g1');
      final g2Before = asksFor(chat, 'g2');
      await t.pump(const Duration(seconds: 30));
      await hop(t);
      expect(
        asksFor(chat, 'g1'),
        g1Before,
        reason: 'a dropped message was sent into a group the member left',
      );
      expect(
        asksFor(chat, 'g2'),
        greaterThan(g2Before),
        reason: 'the other chat stopped retrying',
      );
      expect(
        c.read(draftsProvider.notifier).draftFor('g1').text,
        isEmpty,
        reason: 'dropped bodies are not restored to the draft',
      );
    });

    testWidgets('nothing queued: false', (t) async {
      final chat = groups();
      final c = await start(t, chat);
      expect(c.read(sendQueueProvider.notifier).dropForLeft('g1'), isFalse);
    });

    testWidgets('a send in flight when dropped, then failing, is neither '
        'retried nor restored', (t) async {
      final chat = groups();
      final c = await start(t, chat);
      c.read(sendQueueProvider.notifier).enqueue('g1', body: 'late');
      await hop(t);
      expect(asksFor(chat, 'g1'), 1, reason: 'fixture: in flight');

      expect(c.read(sendQueueProvider.notifier).dropForLeft('g1'), isTrue);
      chat.fail(0, offline);
      await hop(t);
      await t.pump(const Duration(seconds: 30));
      await hop(t);

      expect(asksFor(chat, 'g1'), 1, reason: 'retried after it was dropped');
      expect(queued(c, 'g1'), isEmpty, reason: 'came back into the queue');
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, isEmpty);
    });
  });

  group('GroupController.leave', () {
    testWidgets('accepted: the chat\'s queue is dropped and its draft '
        'cleared, Ok(true), and the list shows it left; the other chat keeps '
        'its draft', (t) async {
      final chat = groups();
      final c = await start(t, chat);
      await queueOffline(t, c, chat, 'g1', ['a', 'b']);
      final drafts = c.read(draftsProvider.notifier)
        ..setText('g1', 'half a thought')
        ..setText('g2', 'keep me');

      final f = c.read(groupControllerProvider).leave('g1');
      await hop(t);
      final r = await f;
      await hop(t);

      expect(r, isA<Ok<bool>>());
      expect((r as Ok<bool>).value, isTrue, reason: 'something was dropped');
      expect(chat.groupWrites, ['leave:g1']);
      expect(queued(c, 'g1'), isEmpty);
      expect(drafts.draftFor('g1').text, isEmpty);
      expect(drafts.draftFor('g2').text, 'keep me');
      expect(inList(c, 'g1')?.hasLeft, isTrue, reason: 'list not re-read');
      expect(inList(c, 'g1'), isNotNull, reason: 'a left group stays listed');

      final before = asksFor(chat, 'g1');
      await t.pump(const Duration(seconds: 30));
      await hop(t);
      expect(asksFor(chat, 'g1'), before, reason: 'sent after leaving');
    });

    testWidgets('nothing queued: Ok(false), the draft still cleared', (
      t,
    ) async {
      final chat = groups();
      final c = await start(t, chat);
      c.read(draftsProvider.notifier).setText('g1', 'bye all');

      final f = c.read(groupControllerProvider).leave('g1');
      await hop(t);
      final r = await f;

      expect((r as Ok<bool>).value, isFalse);
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, isEmpty);
    });

    testWidgets('refused: the failure comes back and nothing is dropped', (
      t,
    ) async {
      final chat = groups()..leaveResult = const Err(DeniedFailure());
      final c = await start(t, chat);
      await queueOffline(t, c, chat, 'g1', ['a']);
      c.read(draftsProvider.notifier).setText('g1', 'still mine');

      final f = c.read(groupControllerProvider).leave('g1');
      await hop(t);
      final r = await f;
      await hop(t);

      expect(r, isA<Err<bool>>());
      expect((r as Err<bool>).failure, isA<DeniedFailure>());
      expect(queued(c, 'g1'), hasLength(1));
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, 'still mine');
      expect(inList(c, 'g1')?.hasLeft, isFalse);
      c.dispose(); // its retry is still waiting; the queue cancels it
    });

    testWidgets('nothing is dropped while the server has not answered', (
      t,
    ) async {
      final chat = groups()..holdGroupWrite();
      final c = await start(t, chat);
      await queueOffline(t, c, chat, 'g1', ['a']);
      c.read(draftsProvider.notifier).setText('g1', 'wait');

      final f = c.read(groupControllerProvider).leave('g1');
      await hop(t);
      expect(queued(c, 'g1'), hasLength(1), reason: 'dropped before an answer');
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, 'wait');

      chat.releaseGroupWrite();
      await hop(t);
      await f;
      await hop(t);
      expect(queued(c, 'g1'), isEmpty);
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, isEmpty);
    });
  });

  group('GroupController admin actions', () {
    test('each passes its arguments exactly and the roster and events '
        'on screen are re-read', () async {
      final chat = groups();
      final c = await startReal(chat);
      c.listen(groupRosterProvider('g1'), (_, _) {});
      c.listen(groupEventsProvider('g1'), (_, _) {});
      await settle();
      final g = c.read(groupControllerProvider);
      GroupMember? row(String id) => c
          .read(groupRosterProvider('g1'))
          .value
          ?.where((m) => m.member.userId == id)
          .lastOrNull;

      final removed = g.removeMember('g1', 'u2');
      await settle();
      expect(await removed, isA<Ok<void>>());
      await settle();
      expect(row('u2')?.leftReason, LeftReason.removed);
      expect(c.read(groupEventsProvider('g1')).value?.map((e) => e.kind), [
        GroupEventKind.removed,
      ]);

      final added = g.addMembers('g1', ['u4'], withHistory: false);
      await settle();
      expect(await added, isA<Ok<void>>());
      await settle();
      expect(row('u4')?.hasLeft, isFalse);

      final admin = g.setAdmin('g1', 'u3', isAdmin: true);
      await settle();
      expect(await admin, isA<Ok<void>>());
      await settle();
      expect(row('u3')?.isAdmin, isTrue);

      expect(chat.groupWrites, [
        'remove:g1:u2',
        'add:g1:u4:false',
        'admin:g1:u3:true',
      ]);
    });

    test('withHistory: true reaches the server as true', () async {
      final chat = groups();
      final c = await startReal(chat);
      final f = c.read(groupControllerProvider).addMembers('g1', [
        'u4',
        'u2',
      ], withHistory: true);
      await settle();
      await f;
      expect(chat.groupWrites, ['add:g1:u4,u2:true']);
    });

    test('a refusal comes back as the failure, for each action', () async {
      final chat = groups()
        ..removeResult = const Err(DeniedFailure())
        ..addResult = const Err(NetworkFailure('No connection'))
        ..setAdminResult = const Err(ProviderFailure('needs an admin'));
      final c = await startReal(chat);
      final g = c.read(groupControllerProvider);
      final r1 = g.removeMember('g1', 'u2');
      final r2 = g.addMembers('g1', ['u4'], withHistory: true);
      final r3 = g.setAdmin('g1', 'u1', isAdmin: false);
      await settle();
      expect(((await r1) as Err).failure, isA<DeniedFailure>());
      expect(((await r2) as Err).failure, isA<NetworkFailure>());
      expect(((await r3) as Err).failure, isA<ProviderFailure>());
    });
  });

  group('leftConversationGuardProvider', () {
    testWidgets('a group found to be left on a list refresh loses its queue '
        'and its draft; another chat keeps its own', (t) async {
      final chat = groups();
      final c = await start(t, chat);
      c.listen(leftConversationGuardProvider, (_, _) {});
      await queueOffline(t, c, chat, 'g1', ['a']);
      c.read(draftsProvider.notifier)
        ..setText('g1', 'never sent')
        ..setText('g2', 'keep me');
      await hop(t);
      expect(queued(c, 'g1'), hasLength(1), reason: 'dropped too early');

      // An admin removed the member elsewhere; the next list read says so.
      chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Trip', hasLeft: true),
        Conversation(id: 'g2', title: 'Club'),
      ]);
      final r = c.read(conversationListProvider.notifier).refresh();
      await hop(t);
      await r;
      await hop(t);

      expect(queued(c, 'g1'), isEmpty);
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, isEmpty);
      expect(c.read(draftsProvider.notifier).draftFor('g2').text, 'keep me');
      final before = asksFor(chat, 'g1');
      await t.pump(const Duration(seconds: 30));
      await hop(t);
      expect(asksFor(chat, 'g1'), before, reason: 'retried after removal');
    });
  });

  group('channels of a group the member has left', () {
    test('the reads: subscription is left when the open group turns '
        'out to be left', () async {
      final chat = groups();
      final c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          profileRepositoryProvider.overrideWithValue(
            ProfileFake(
              profile: const OwnProfile(
                userId: 'u1',
                displayName: 'Maya',
                tag: 'maya',
                onboardingDone: true,
                shareReadStatus: true,
              ),
            ),
          ),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      );
      await settled(c);
      c.listen(ownProfileProvider, (_, _) {});
      c.listen(conversationListProvider, (_, _) {});
      await settle();
      c.read(openConversationProvider.notifier).open('g1');
      c.listen(readMarksProvider, (_, _) {});
      await settle();
      expect(
        chat.readSubscriptions - chat.canceledReadSubscriptions,
        1,
        reason: 'fixture: listening to g1 reads',
      );

      chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Trip', hasLeft: true),
      ]);
      final r = c.read(conversationListProvider.notifier).refresh();
      await settle();
      await r;
      await settle();

      expect(
        chat.readSubscriptions - chat.canceledReadSubscriptions,
        0,
        reason: 'still joined to reads:g1 after leaving',
      );
      expect(c.read(readMarksProvider).value, isEmpty);
    });

    test('the typing: channel is closed when the open group turns out '
        'to be left', () async {
      final chat = groups();
      final presence = PresenceFake();
      final c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(presence),
          profileRepositoryProvider.overrideWithValue(
            ProfileFake(
              profile: const OwnProfile(
                userId: 'u1',
                displayName: 'Maya',
                tag: 'maya',
                onboardingDone: true,
                shareTyping: true,
              ),
            ),
          ),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      );
      await settled(c);
      c.listen(ownProfileProvider, (_, _) {});
      c.listen(conversationListProvider, (_, _) {});
      await settle();
      c.read(openConversationProvider.notifier).open('g1');
      c.listen(typingProvider, (_, _) {});
      await settle();
      expect(
        presence.typingChannels.where((ch) => !ch.closed),
        hasLength(1),
        reason: 'fixture: joined typing:g1',
      );

      chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Trip', hasLeft: true),
      ]);
      final r = c.read(conversationListProvider.notifier).refresh();
      await settle();
      await r;
      await settle();

      expect(
        presence.typingChannels.where((ch) => !ch.closed),
        isEmpty,
        reason: 'still joined to typing:g1 after leaving',
      );
    });
  });

  group('chatTimelineProvider', () {
    Message msg(String id, int minute, String conv) => Message(
      id: id,
      conversationId: conv,
      senderId: 'u2',
      body: id,
      createdAt: t0.add(Duration(minutes: minute)),
    );
    GroupEvent ev(String id, int minute) => GroupEvent(
      id: id,
      conversationId: 'g1',
      kind: GroupEventKind.left,
      subjectId: 'u3',
      createdAt: t0.add(Duration(minutes: minute)),
    );
    String label(TimelineEntry e) => switch (e) {
      MessageEntry(:final message) => 'm:${message.id}',
      EventEntry(:final event) => 'e:${event.id}',
    };

    test('a group\'s messages and its admin events, merged by time', () async {
      final chat = groups()
        ..history['g1'] = [msg('m1', 0, 'g1'), msg('m2', 10, 'g1')]
        ..events['g1'] = [ev('e2', 12), ev('e1', 5)];
      final c = await startReal(chat);
      c.read(openConversationProvider.notifier).open('g1');
      c.listen(chatTimelineProvider, (_, _) {});
      await settle();
      expect(c.read(chatTimelineProvider).map(label), [
        'm:m1',
        'e:e1',
        'm:m2',
        'e:e2',
      ]);
    });

    test('a 1:1 never asks for events', () async {
      final chat = groups()
        ..conversationsResult = const Ok([Conversation(id: 'c1', other: bob)])
        ..history['c1'] = [msg('m1', 0, 'c1')];
      final c = await startReal(chat);
      c.read(openConversationProvider.notifier).open('c1');
      c.listen(chatTimelineProvider, (_, _) {});
      await settle();
      expect(c.read(chatTimelineProvider).map(label), ['m:m1']);
      expect(chat.calls.where((x) => x.startsWith('groupEvents')), isEmpty);
    });
  });
}
