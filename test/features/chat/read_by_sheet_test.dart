// "Read by", from the product rule: in a group, touching your own message
// shows who has read it and when (the time as lastSeenLabel words it), and
// "Nobody yet" when nobody has. Only members who share read status can be
// listed. Run under TZ=JST-9 like every unit test: the times below are UTC
// instants whose local date differs from their UTC date.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/domain/last_seen.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');
const dee = Member(userId: 'u4', displayName: 'Dee');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// Long ago, so the label is a date and does not move with the clock.
final sentAt = DateTime.utc(2020, 1, 1, 10);
// 20:30 UTC on the 1st is 05:30 on the 2nd in Tokyo.
final bobRead = DateTime.utc(2020, 1, 1, 20, 30);
final cemRead = DateTime.utc(2020, 1, 3, 9);

Message msg(String from) => Message(
  id: 'm1',
  conversationId: 'g1',
  senderId: from,
  body: 'hello club',
  createdAt: sentAt,
);

Future<void> pump(
  WidgetTester t,
  List<ReadMark> marks, {
  String from = 'u1',
  bool group = true,
}) async {
  final chat = ChatFake()
    ..messagesResult = Ok([msg(from)])
    ..membersResult = const Ok([bob, cem, dee])
    ..readMarksData['g1'] = marks;
  chat.roster['g1'] = [me, bob, cem, dee];
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  c.read(openConversationProvider.notifier).open('g1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: MessageScreen(title: 'Club', group: group),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> touch(WidgetTester t) async {
  await t.longPress(find.byKey(const ValueKey('message-m1')));
  await t.pumpAndSettle();
}

Future<void> openReadBy(WidgetTester t) async {
  await touch(t);
  expect(find.text('Read by'), findsOneWidget, reason: 'no "Read by" offered');
  await t.tap(find.text('Read by'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('lists each member who has read it, with when', (t) async {
    await pump(t, [
      ReadMark(userId: 'u2', shares: true, readAt: bobRead),
      ReadMark(userId: 'u3', shares: true, readAt: cemRead),
    ]);
    await openReadBy(t);

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Cem'), findsOneWidget);
    final now = DateTime.now();
    expect(find.text(lastSeenLabel(bobRead, now)), findsOneWidget);
    expect(find.text(lastSeenLabel(cemRead, now)), findsOneWidget);
    expect(
      find.textContaining('02.01.20'),
      findsOneWidget,
      reason: "Bob's time must be the local date, not the UTC one",
    );
    expect(find.text('Nobody yet'), findsNothing);
  });

  testWidgets('leaves out who read only before it was sent, who never '
      'read, and who does not share', (t) async {
    await pump(t, [
      ReadMark(userId: 'u2', shares: true, readAt: bobRead),
      ReadMark(
        userId: 'u3',
        shares: true,
        readAt: sentAt.subtract(const Duration(days: 1)),
      ),
      const ReadMark(userId: 'u4', shares: false),
    ]);
    await openReadBy(t);

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Cem'), findsNothing);
    expect(find.text('Dee'), findsNothing);
    expect(find.text('Nobody yet'), findsNothing);
  });

  testWidgets('"Nobody yet" when nobody has read it', (t) async {
    await pump(t, [
      const ReadMark(userId: 'u2', shares: true),
      ReadMark(
        userId: 'u3',
        shares: true,
        readAt: sentAt.subtract(const Duration(minutes: 1)),
      ),
    ]);
    await openReadBy(t);

    expect(find.text('Nobody yet'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Cem'), findsNothing);
  });

  testWidgets('"Nobody yet" when nobody shares read status', (t) async {
    await pump(t, const [
      ReadMark(userId: 'u2', shares: false),
      ReadMark(userId: 'u3', shares: false),
    ]);
    await openReadBy(t);

    expect(find.text('Nobody yet'), findsOneWidget);
  });

  testWidgets("someone else's message offers no \"Read by\"", (t) async {
    await pump(t, [
      ReadMark(userId: 'u3', shares: true, readAt: cemRead),
    ], from: 'u2');
    await touch(t);
    expect(find.text('Read by'), findsNothing);
  });

  testWidgets('a 1:1 offers no "Read by": the bubble already says it', (
    t,
  ) async {
    await pump(t, [
      ReadMark(userId: 'u2', shares: true, readAt: bobRead),
    ], group: false);
    await touch(t);
    expect(find.text('Read by'), findsNothing);
  });
}
