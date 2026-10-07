// The contact bubble in a real MessageScreen and the chat-list preview,
// written from the contract: name, number, Save (native creator prefilled),
// no Message action, plain text when the body does not parse, no forward or
// edit in the menu, preview line in English and Turkish.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';

import '../../support/chat_launcher.dart';
import '../../support/contact_fakes.dart';
import '../../support/fakes.dart';
import 'conversation_list_live_test.dart' show scope;

Finder k(String key) => find.byKey(ValueKey(key));

Message contactMsg({
  String id = 'm1',
  String from = 'u2',
  String body = 'Ann Lee\n+90 555 111',
  bool sending = false,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.now(),
  contact: true,
  sending: sending,
);

void main() {
  group('Contact card', () {
    testWidgets('card shows name and number', (tester) async {
      await openChat(tester, messages: [contactMsg()]);
      await settle(tester);

      expect(k('contact-m1'), findsOneWidget);
      expect(
        find.descendant(of: k('contact-m1'), matching: find.text('Ann Lee')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: k('contact-m1'),
          matching: find.text('+90 555 111'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Save opens the native creator prefilled', (tester) async {
      final book = FakePhoneBook();
      await openChat(tester, messages: [contactMsg()], phoneBook: book);
      await settle(tester);

      await tester.tap(k('contact-save-m1'));
      await settle(tester);

      expect(book.added.length, 1);
      expect(book.added.single.name, 'Ann Lee');
      expect(book.added.single.phone, '+90 555 111');
    });

    testWidgets('no Message action', (tester) async {
      await openChat(tester, messages: [contactMsg()]);
      await settle(tester);

      expect(
        find.descendant(of: k('contact-m1'), matching: find.text('Message')),
        findsNothing,
      );
    });

    testWidgets('unparseable body shows plain text', (tester) async {
      await openChat(tester, messages: [contactMsg(body: 'just some text')]);
      await settle(tester);

      expect(k('contact-save-m1'), findsNothing);
      expect(find.text('just some text'), findsOneWidget);
    });

    testWidgets('my own pending contact still shows the card', (tester) async {
      await openChat(tester, messages: [contactMsg(from: 'u1', sending: true)]);
      await settle(tester);

      expect(k('contact-m1'), findsOneWidget);
    });

    testWidgets('the menu of my sent contact has no forward and no edit', (
      tester,
    ) async {
      await openChat(tester, messages: [contactMsg(from: 'u1')]);
      await tester.longPress(bubble('m1'));
      await tester.pumpAndSettle();
      expect(k('message-menu'), findsOneWidget);
      expect(k('menu-reply'), findsOneWidget, reason: 'menu has actions');
      expect(k('menu-forward'), findsNothing);
      expect(k('menu-edit'), findsNothing);
    });

    testWidgets('control: my sent text message offers forward and edit', (
      tester,
    ) async {
      await openChat(
        tester,
        messages: [
          Message(
            id: 'm1',
            conversationId: 'c1',
            senderId: 'u1',
            body: 'Hello',
            createdAt: DateTime.now(),
          ),
        ],
      );
      await tester.longPress(bubble('m1'));
      await tester.pumpAndSettle();
      expect(k('menu-forward'), findsOneWidget);
      expect(k('menu-edit'), findsOneWidget);
    });

    testWidgets('the chat list shows a contact in English', (tester) async {
      await list(tester, '${contactPreviewPrefix}Ann Lee');
      expect(
        find.descendant(
          of: k('preview-c1'),
          matching: find.text('\u{1F464} Contact: Ann Lee'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('the chat list shows a contact in Turkish', (tester) async {
      await list(
        tester,
        '${contactPreviewPrefix}Ann Lee',
        locale: const Locale('tr'),
      );
      expect(
        find.descendant(
          of: k('preview-c1'),
          matching: find.text('\u{1F464} Kişi: Ann Lee'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });
  });
}

/// The chat list whose only chat c1 last showed [lastMessage].
Future<void> list(WidgetTester t, String lastMessage, {Locale? locale}) async {
  final chat = ChatFake()
    ..conversationsResult = Ok([
      Conversation(
        id: 'c1',
        other: bob,
        lastMessage: lastMessage,
        lastMessageAt: DateTime.now().toUtc(),
        lastSenderId: bob.userId,
      ),
    ]);
  final c = scope(chat);
  addTearDown(c.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const ConversationList(),
      ),
    ),
  );
  await t.pumpAndSettle();
}
