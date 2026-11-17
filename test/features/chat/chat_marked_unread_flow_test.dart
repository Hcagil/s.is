import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';

import '../../support/fakes.dart';
import '../../support/mark_fakes.dart';
import '../../support/sis_ui.dart' as ui;
import '../../support/l10n.dart';
import '../../support/chat_card_pump.dart';

void main() {
  group('marked unread flow', () {
    testWidgets('dot shows for a hand-marked chat with no count', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, marked: true),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      expect(byKey('marked-dot-c1'), findsOneWidget);
      expect(byKey('marked-dot-c2'), findsNothing);
    });

    testWidgets('the count pill wins over the dot', (WidgetTester t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, unread: 3, marked: true),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      expect(byKey('unread-c1'), findsOneWidget);
      expect(byKey('marked-dot-c1'), findsNothing);
    });

    testWidgets('no mark, no count: no dot, no pill', (WidgetTester t) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      expect(byKey('marked-dot-c1'), findsNothing);
      expect(byKey('unread-c1'), findsNothing);
    });

    testWidgets('Mark as unread: dot, snackbar with Undo, one server call', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(mark.calls, ['c1']);
      expect(find.text(l10nEn.chatMarkedUnread), findsOneWidget);
      expect(find.text(l10nEn.chatDeleteUndo), findsOneWidget);
      expect(byKey('marked-dot-c1'), findsOneWidget);
    });

    testWidgets('Undo takes the mark back', (WidgetTester t) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text(l10nEn.chatDeleteUndo));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(chat.markedRead, contains('c1'));
      expect(byKey('marked-dot-c1'), findsNothing);
    });

    testWidgets('the snackbar lasts 5 seconds', (WidgetTester t) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pump();
      await t.pump(const Duration(seconds: 4));
      expect(find.text(l10nEn.chatMarkedUnread), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text(l10nEn.chatMarkedUnread), findsNothing);
      expect(byKey('marked-dot-c1'), findsOneWidget);
    });

    testWidgets('a refusal shows an error notice, no dot, no snackbar', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      final mark = MarkFake()..result = const Err(DeniedFailure());
      await pumpCardList(t, chat: chat, mark: mark);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(ui.notice, findsOneWidget);
      expect(find.text(l10nEn.chatMarkedUnread), findsNothing);
      expect(byKey('marked-dot-c1'), findsNothing);
      await ui.drainNotice(t);
    });

    testWidgets('opening the chat clears the mark', (WidgetTester t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', bob, 1, marked: true)]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark);
      await t.tap(byKey('conversation-c1'));
      await t.pumpAndSettle();
      expect(chat.markedRead, contains('c1'));
    });

    testWidgets('Turkish snackbar', (WidgetTester t) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      final mark = MarkFake();
      await pumpCardList(t, chat: chat, mark: mark, locale: const Locale('tr'));
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text(l10nTr.chatMarkedUnread), findsOneWidget);
      expect(find.text(l10nTr.chatMenuMarkUnread), findsNothing);
    });
  });
}
