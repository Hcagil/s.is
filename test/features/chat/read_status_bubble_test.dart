// The sender's own bubble is a little grey until it is read, normal once
// read (DECISIONS 2026-09-24). Grey is judged the way it is drawn: any
// opacity below 1 on the bubble or around it. Written from the product rule,
// not from how the screen builds the bubble.
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

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final sentAt = DateTime.utc(2026, 9, 25, 12);
final after = sentAt.add(const Duration(minutes: 1));
final before = sentAt.subtract(const Duration(minutes: 1));

Message msg(String id, {String from = 'u1', String conversation = 'c1'}) =>
    Message(
      id: id,
      conversationId: conversation,
      senderId: from,
      body: 'hi $id',
      createdAt: sentAt,
    );

Future<void> pump(
  WidgetTester t,
  ChatFake chat, {
  String id = 'c1',
  bool group = false,
}) async {
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
  c.read(openConversationProvider.notifier).open(id);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: MessageScreen(title: group ? 'Club' : 'Bob', group: group),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// Whether the bubble of message [id] is drawn below full opacity.
bool grey(WidgetTester t, String id) {
  final bubble = find.byKey(ValueKey('message-$id'));
  expect(bubble, findsOneWidget, reason: 'message $id is not on screen');
  double of(Element e) => switch (e.widget) {
    final Opacity o => o.opacity,
    final FadeTransition f => f.opacity.value,
    final AnimatedOpacity a => a.opacity,
    _ => 1,
  };
  bool fade(Widget w) =>
      w is Opacity || w is FadeTransition || w is AnimatedOpacity;
  // Only between the screen and the bubble: a route's own transition above
  // the screen is not the bubble's colour.
  final screen = find.byType(MessageScreen).evaluate().single;
  bool insideScreen(Element e) {
    var inside = false;
    e.visitAncestorElements((a) => !(inside = a == screen));
    return inside;
  }

  return [
    ...find
        .ancestor(of: bubble, matching: find.byWidgetPredicate(fade))
        .evaluate()
        .where(insideScreen),
    ...find
        .descendant(of: bubble, matching: find.byWidgetPredicate(fade))
        .evaluate(),
  ].any((e) => of(e) < 1);
}

void main() {
  group('1:1', () {
    testWidgets('my message is grey until the other member has read it', (
      t,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: before),
        ];
      await pump(t, chat);
      expect(grey(t, 'm1'), isTrue);
    });

    testWidgets('never read at all: grey', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      expect(grey(t, 'm1'), isTrue);
    });

    testWidgets('read: normal', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: after),
        ];
      await pump(t, chat);
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('the other member does not share (or I do not): normal', (
      t,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
      await pump(t, chat);
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('their message is never grey', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: 'u2')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('read status that cannot be loaded: normal, messages shown', (
      t,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksResult = const Err(NetworkFailure('offline'));
      await pump(t, chat);
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('the other member reading it turns it normal, live', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      expect(grey(t, 'm1'), isTrue, reason: 'fixture');

      chat.deliverRead(
        'c1',
        ReadMark(userId: 'u2', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('an older message read, a newer one not', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([
          Message(
            id: 'old',
            conversationId: 'c1',
            senderId: 'u1',
            body: 'old',
            createdAt: before.subtract(const Duration(minutes: 1)),
          ),
          msg('new'),
        ])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: before),
        ];
      await pump(t, chat);
      expect(grey(t, 'old'), isFalse);
      expect(grey(t, 'new'), isTrue);
    });
  });

  group('group', () {
    Future<void> inGroup(WidgetTester t, List<ReadMark> marks) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', conversation: 'g1')])
        ..readMarksData['g1'] = marks;
      await pump(t, chat, id: 'g1', group: true);
    }

    testWidgets('read by one sharing member, not another: grey', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after),
        ReadMark(userId: 'u3', shares: true, readAt: before),
      ]);
      expect(grey(t, 'm1'), isTrue);
    });

    testWidgets('read by every sharing member: normal', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after),
        ReadMark(userId: 'u3', shares: true, readAt: after),
      ]);
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('a member who does not share never holds it grey', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after),
        const ReadMark(userId: 'u3', shares: false),
      ]);
      expect(grey(t, 'm1'), isFalse);
    });

    testWidgets('nobody shares: normal', (t) async {
      await inGroup(t, const [
        ReadMark(userId: 'u2', shares: false),
        ReadMark(userId: 'u3', shares: false),
      ]);
      expect(grey(t, 'm1'), isFalse);
    });
  });
}
