// The sender's own bubble shows where it stands with a tick beside the time
// (owner rule Q7), replacing the old yellow unread edge: one grey tick =
// sent, two grey = delivered to EVERY recipient, two blue = read by EVERY
// recipient (in a group, all of them). A member with read receipts off never
// counts as read. Others' bubbles have no tick. The bubble keeps full
// brightness and its size whatever the tick shows. Judged on the real
// MessageScreen: the DeliveryTick at `ValueKey('tick-$id')`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/delivery_fakes.dart';
import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

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
  Brightness brightness = Brightness.light,
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(brightness),
        home: MessageScreen(title: group ? 'Club' : 'Bob', group: group),
      ),
    ),
  );
  await t.pumpAndSettle();
}

const yellow = Color(0xFFFFD54F);

/// What message [id]'s tick shows; null when it has none.
Delivery? tickOf(WidgetTester t, String id) {
  expect(
    find.byKey(ValueKey('message-$id')),
    findsOneWidget,
    reason: 'message $id is not on screen',
  );
  final f = find.byKey(ValueKey('tick-$id'));
  if (f.evaluate().isEmpty) return null;
  return t.widget<DeliveryTick>(f).delivery;
}

/// The old amber edge is gone: no border on [id]'s bubble is yellow.
void noYellowEdge(WidgetTester t, String id) {
  for (final e
      in find
          .descendant(
            of: find.byKey(ValueKey('message-$id')),
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.border is Border) {
      final b = d.border! as Border;
      for (final s in [b.top, b.right, b.bottom, b.left]) {
        expect(s.color, isNot(yellow), reason: '$id still has the edge');
      }
    }
  }
}

/// My message [id] shows [want], at full brightness, without the old edge.
void shows(WidgetTester t, String id, Delivery want) {
  expect(tickOf(t, id), want, reason: 'tick of $id');
  expect(dimmed(t, id), isFalse, reason: '$id is dimmed');
  noYellowEdge(t, id);
}

/// Drawn below full brightness: an opacity under 1 between the screen and
/// the bubble, or inside it (the old grey, now gone).
bool dimmed(WidgetTester t, String id) {
  final bubble = find.byKey(ValueKey('message-$id'));
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

  final inTick = find
      .descendant(
        of: find.byKey(ValueKey('tick-$id')),
        matching: find.byWidgetPredicate(fade),
        matchRoot: true,
      )
      .evaluate()
      .toSet();
  return [
    ...find
        .ancestor(of: bubble, matching: find.byWidgetPredicate(fade))
        .evaluate()
        .where(insideScreen),
    // The tick's own fade is how a tick is drawn, not the bubble dimmed.
    ...find
        .descendant(of: bubble, matching: find.byWidgetPredicate(fade))
        .evaluate()
        .where((e) => !inTick.contains(e)),
  ].any((e) => of(e) < 1);
}

Size sizeOf(WidgetTester t, String id) =>
    t.getSize(find.byKey(ValueKey('message-$id')));

void main() {
  group('1:1', () {
    testWidgets('stored, Bob has not received it: one tick', (t) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: before),
        ];
      await pump(t, chat);
      shows(t, 'm1', Delivery.sent);
    });

    testWidgets('on the phone of Bob, not read: two grey', (t) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, deliveredAt: sentAt),
        ];
      await pump(t, chat);
      shows(t, 'm1', Delivery.delivered);
    });

    testWidgets('read: two blue, full brightness', (t) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(
            userId: 'u2',
            shares: true,
            readAt: after,
            deliveredAt: after,
          ),
        ];
      await pump(t, chat);
      shows(t, 'm1', Delivery.read);
    });

    testWidgets('Bob has receipts off (or I do): delivered stays two grey', (
      t,
    ) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: false, deliveredAt: after),
        ];
      await pump(t, chat);
      shows(t, 'm1', Delivery.delivered);
    });

    testWidgets('their message has no tick', (t) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1', from: 'u2'), msg('m2', from: 'u2')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, deliveredAt: after),
        ];
      await pump(t, chat);
      expect(tickOf(t, 'm1'), isNull);
      expect(tickOf(t, 'm2'), isNull);
      expect(dimmed(t, 'm1'), isFalse);
    });

    testWidgets('read marks that cannot be loaded: one tick, messages shown', (
      t,
    ) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksResult = const Err(NetworkFailure('offline'));
      await pump(t, chat);
      shows(t, 'm1', Delivery.sent);
    });

    testWidgets('Bob receiving then reading it moves the tick, live, and the '
        'bubble keeps its size', (t) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      shows(t, 'm1', Delivery.sent);
      final size = sizeOf(t, 'm1');

      chat.deliverDelivery('c1', 'u2', sentAt);
      await t.pumpAndSettle();
      shows(t, 'm1', Delivery.delivered);
      expect(sizeOf(t, 'm1'), size);

      chat.deliverRead(
        'c1',
        ReadMark(userId: 'u2', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      shows(t, 'm1', Delivery.read);
      expect(sizeOf(t, 'm1'), size);
    });

    testWidgets('an older message read, a newer one only delivered', (t) async {
      final chat = DeliveryChat()
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
          ReadMark(
            userId: 'u2',
            shares: true,
            readAt: before,
            deliveredAt: sentAt,
          ),
        ];
      await pump(t, chat);
      shows(t, 'old', Delivery.read);
      shows(t, 'new', Delivery.delivered);
    });
  });

  group('dark theme', () {
    testWidgets('mine: the tick; theirs: none', (t) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1'), msg('m2', from: 'u2')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, deliveredAt: after),
        ];
      await pump(t, chat, brightness: Brightness.dark);
      shows(t, 'm1', Delivery.delivered);
      expect(tickOf(t, 'm2'), isNull);
    });
  });

  group('group', () {
    Future<DeliveryChat> inGroup(WidgetTester t, List<ReadMark> marks) async {
      final chat = DeliveryChat()
        ..messagesResult = Ok([msg('m1', conversation: 'g1')])
        ..readMarksData['g1'] = marks;
      await pump(t, chat, id: 'g1', group: true);
      return chat;
    }

    testWidgets('read by one, not received by another: one tick', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after, deliveredAt: after),
        const ReadMark(userId: 'u3', shares: true),
      ]);
      shows(t, 'm1', Delivery.sent);
    });

    testWidgets('read by one, received by the other: two grey -- one reader '
        'is no longer enough', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after, deliveredAt: after),
        ReadMark(
          userId: 'u3',
          shares: true,
          readAt: before,
          deliveredAt: after,
        ),
      ]);
      shows(t, 'm1', Delivery.delivered);
    });

    testWidgets('read by every member: two blue', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after, deliveredAt: after),
        ReadMark(userId: 'u3', shares: true, readAt: after, deliveredAt: after),
      ]);
      shows(t, 'm1', Delivery.read);
    });

    testWidgets('everyone else read it, one member has receipts off: two '
        'grey', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after, deliveredAt: after),
        ReadMark(userId: 'u3', shares: false, deliveredAt: after),
      ]);
      shows(t, 'm1', Delivery.delivered);
    });

    testWidgets('the last reader turns it blue, live; the first does not', (
      t,
    ) async {
      final chat = await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, deliveredAt: after),
        ReadMark(userId: 'u3', shares: true, deliveredAt: after),
      ]);
      shows(t, 'm1', Delivery.delivered);

      chat.deliverRead(
        'g1',
        ReadMark(userId: 'u3', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      shows(t, 'm1', Delivery.delivered);

      chat.deliverRead(
        'g1',
        ReadMark(userId: 'u2', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      shows(t, 'm1', Delivery.read);
    });

    testWidgets('the last delivery turns one tick into two, live', (t) async {
      final chat = await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, deliveredAt: after),
        const ReadMark(userId: 'u3', shares: true),
      ]);
      shows(t, 'm1', Delivery.sent);
      chat.deliverDelivery('g1', 'u3', sentAt);
      await t.pumpAndSettle();
      shows(t, 'm1', Delivery.delivered);
    });
  });
}
