import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';

import '../../support/fakes.dart';
import '../../support/mark_fakes.dart';
import '../../support/chat_card_pump.dart';

void main() {
  group('mark as read clears the hand-set dot', () {
    testWidgets('long-press menu', (WidgetTester t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, marked: true),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      expect(byKey('marked-dot-c1'), findsOneWidget);

      expect(weight(t, byKey('conversation-c1')),
          greaterThan(weight(t, byKey('conversation-c2'))));

      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pumpAndSettle();

      expect(chat.markedRead, contains('c1'));
      expect(byKey('marked-dot-c1'), findsNothing, reason: 'dot stayed');
      expect(weight(t, byKey('conversation-c1')),
          equals(weight(t, byKey('conversation-c2'))));
    });

    testWidgets('selection bar', (WidgetTester t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, marked: true),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      expect(byKey('marked-dot-c1'), findsOneWidget);

      expect(weight(t, byKey('conversation-c1')),
          greaterThan(weight(t, byKey('conversation-c2'))));

      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      await t.tap(byKey('chat-menu-select'));
      await t.pumpAndSettle();
      await t.tap(byKey('selection-more'));
      await t.pumpAndSettle();
      await t.tap(byKey('selection-read'));
      await t.pumpAndSettle();

      expect(chat.markedRead, contains('c1'));
      expect(byKey('marked-dot-c1'), findsNothing, reason: 'dot stayed');
      expect(weight(t, byKey('conversation-c1')),
          equals(weight(t, byKey('conversation-c2'))));
    });
  });
}
