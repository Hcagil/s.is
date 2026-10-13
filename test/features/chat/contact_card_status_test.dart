// The contact bubble keeps the usual delivery ticks, pending clock and
// reaction chips (contract), through the real message screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/reaction.dart';

import '../../support/chat_launcher.dart';
import '../../support/reaction_fakes.dart';

Finder k(String key) => find.byKey(ValueKey(key));

Message contactMsg({String from = 'u1', bool sending = false}) => Message(
  id: 'm1',
  conversationId: 'c1',
  senderId: from,
  body: 'Ann Lee\n+90 555 111',
  createdAt: DateTime.now(),
  contact: true,
  sending: sending,
);

Iterable<Delivery> ticks(WidgetTester t) => t
    .widgetList<DeliveryTick>(
      find.descendant(of: k('contact-m1'), matching: find.byType(DeliveryTick)),
    )
    .map((d) => d.delivery);

void main() {
  group('ContactCardStatus', () {
    testWidgets('my pending contact shows the clock', (WidgetTester t) async {
      await openChat(t, messages: [contactMsg(sending: true)]);
      expect(ticks(t), [Delivery.pending]);
    });

    testWidgets('my sent contact shows a tick, not the clock', (
      WidgetTester t,
    ) async {
      await openChat(t, messages: [contactMsg()]);
      expect(ticks(t), hasLength(1));
      expect(ticks(t).single, isNot(Delivery.pending));
    });

    testWidgets('a contact from someone else shows no tick', (
      WidgetTester t,
    ) async {
      await openChat(t, messages: [contactMsg(from: 'u2')]);
      expect(ticks(t), isEmpty);
      expect(k('contact-m1'), findsOneWidget);
    });

    testWidgets('reactions show under a contact', (WidgetTester t) async {
      final fake = ReactionFake()
        ..seed('c1', [Reaction(messageId: 'm1', userId: 'u2', emoji: '👍')]);
      await openChat(
        t,
        messages: [contactMsg(from: 'u2')],
        reactions: fake,
      );
      expect(k('reactions-m1'), findsOneWidget);
      expect(k('reaction-chip-m1-👍'), findsOneWidget);
    });
  });
}
