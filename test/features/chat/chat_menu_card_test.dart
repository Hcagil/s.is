import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/mark_fakes.dart';
import '../../support/pin_fakes.dart';
import '../../support/sis_ui.dart' as ui;
import '../../support/l10n.dart';
import '../../support/chat_card_pump.dart';

void main() {
  group('chat menu card', () {
    testWidgets('a read chat offers Mark as unread only', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      await pumpCardList(t, chat: chat);
      await openCard(t, 'c1');
      expect(find.text(l10nEn.chatMenuMarkUnread), findsOneWidget);
      expect(find.text(l10nEn.chatSelMarkRead), findsNothing);
    });

    testWidgets('a chat with a count offers Mark as read only', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', bob, 1, unread: 2)]);
      await pumpCardList(t, chat: chat);
      await openCard(t, 'c1');
      expect(find.text(l10nEn.chatSelMarkRead), findsOneWidget);
      expect(find.text(l10nEn.chatMenuMarkUnread), findsNothing);
    });

    testWidgets('a hand-marked chat offers Mark as read only', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', bob, 1, marked: true)]);
      await pumpCardList(t, chat: chat);
      await openCard(t, 'c1');
      expect(find.text(l10nEn.chatSelMarkRead), findsOneWidget);
      expect(find.text(l10nEn.chatMenuMarkUnread), findsNothing);
    });

    testWidgets('marked AND a count: Mark as read only', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, unread: 3, marked: true),
        ]);
      await pumpCardList(t, chat: chat);
      await openCard(t, 'c1');
      expect(find.text(l10nEn.chatSelMarkRead), findsOneWidget);
      expect(find.text(l10nEn.chatMenuMarkUnread), findsNothing);
    });

    testWidgets('Mark as read row calls markRead', (WidgetTester t) async {
      final mark = MarkFake();
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', bob, 1, unread: 2)]);
      await pumpCardList(t, chat: chat, mark: mark);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-unread'));
      await t.pumpAndSettle();
      expect(chat.markedRead, contains('c1'));
      expect(mark.calls, isEmpty);
    });

    testWidgets('Select row starts a selection', (WidgetTester t) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      await pumpCardList(t, chat: chat);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-select'));
      await t.pumpAndSettle();
      expect(byKey('selection-count'), findsOneWidget);
      expect(byKey('chat-menu'), findsNothing);
    });

    testWidgets('Archive row archives the chat', (WidgetTester t) async {
      final archive = ChatArchiveFake();
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      await pumpCardList(t, chat: chat, archive: archive);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-archive'));
      await t.pumpAndSettle();
      expect(
        archive.calls.map((e) => '${e.key}:${e.value}').toList(),
        equals(['c1:true']),
      );
    });

    testWidgets('Delete chat row asks, then deletes', (WidgetTester t) async {
      final del = ChatDeleteFake(
        chat: ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]),
      );
      final chat = del.chat!;
      await pumpCardList(t, chat: chat, del: del);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-delete'));
      await t.pumpAndSettle();
      expect(byKey('delete-chat-ok'), findsOneWidget);
      expect(del.calls, isEmpty);
      await t.tap(byKey('delete-chat-ok'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(byKey('chat-undo-bar'), findsOneWidget);
      expect(del.calls, isEmpty, reason: 'the call waits for the undo bar');
      for (var i = 0; i < 7; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      await t.pumpAndSettle();
      expect(del.calls, equals(['hide:c1']));
    });

    testWidgets('Mute and Pin rows are still on the card', (
      WidgetTester t,
    ) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      await pumpCardList(t, chat: chat);
      await openCard(t, 'c1');
      expect(byKey('chat-menu-mute'), findsOneWidget);
      expect(byKey('chat-menu-pin'), findsOneWidget);
    });

    testWidgets('Pin row pins (limit is 5)', (WidgetTester t) async {
      final pins = ChatPinFake();
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      await pumpCardList(t, chat: chat, pins: pins);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-pin'));
      await t.pumpAndSettle();
      expect(pins.calls, equals(['chat:c1:true']));
    });

    testWidgets('a 6th pin is refused with the limit notice', (
      WidgetTester t,
    ) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final pins = ChatPinFake(pinned: {'p1', 'p2', 'p3', 'p4', 'p5'});
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('p1', bob, 1, pinned: true),
          conv('p2', bob, 2, pinned: true),
          conv('p3', bob, 3, pinned: true),
          conv('p4', bob, 4, pinned: true),
          conv('p5', bob, 5, pinned: true),
          conv('c1', bob, 6),
          conv('c2', cem, 7),
        ]);
      await pumpCardList(t, chat: chat, pins: pins);
      await openCard(t, 'c1');
      await t.tap(byKey('chat-menu-pin'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text(l10nEn.chatPinLimit), findsOneWidget);
      expect(pins.calls, isEmpty);
      await ui.drainNotice(t);
    });

    testWidgets('Turkish: Select row says Seç', (WidgetTester t) async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', bob, 1)]);
      await pumpCardList(t, chat: chat, locale: const Locale('tr'));
      await openCard(t, 'c1');
      expect(find.text(l10nTr.commonSelect), findsOneWidget);
      expect(l10nTr.commonSelect, equals('Seç'));
    });

    testWidgets(
      'the Archived list card has unread, select, archive and delete rows but no pin',
      (WidgetTester t) async {
        final archive = ChatArchiveFake(archived: {'c2'});
        final chat = ChatFake()
          ..conversationsResult = Ok([
            conv('c1', bob, 1),
            conv('c2', cem, 2, archived: true),
          ]);
        await pumpCardList(t, chat: chat, archive: archive);
        await t.drag(byKey('conversation-list'), const Offset(0, 120));
        await t.pumpAndSettle();
        await t.tap(byKey('archived-chats-row'));
        await t.pumpAndSettle();
        await openCard(t, 'c2');
        expect(byKey('chat-menu-unread'), findsOneWidget);
        expect(byKey('chat-menu-select'), findsOneWidget);
        expect(byKey('chat-menu-archive'), findsOneWidget);
        expect(byKey('chat-menu-delete'), findsOneWidget);
        expect(byKey('chat-menu-pin'), findsNothing);
      },
    );
  });
}
