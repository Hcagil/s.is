// The "/" command list, from the contract:
// - matchCommands: prefix match on the name; empty unless the text starts with
//   "/" and has no space or newline yet.
// - the SIS Admin chat and Bacanaks Ozel chat show the list when the box starts
//   with "/"; each row has two lines (command + grey email hint, meaning).
// - a tap fills the box with "/name " (cursor at the end, box focused) and
//   never sends. Edit mode and every other chat: no list.
// - texts in EN and TR.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/bot_command.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/command_list_panel.dart';
import 'package:sis/features/chat/presentation/command_list_row.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/core/failure.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Finder byKey(String k) => find.byKey(ValueKey(k));
final panel = byKey('command-list-panel');

enum Chat { admin, bacanaks, normal, group }

Conversation conv(Chat c) => switch (c) {
  Chat.admin => const Conversation(id: 'c1', title: 'x', isAdminChat: true),
  Chat.bacanaks => const Conversation(
    id: 'c1',
    title: 'x',
    isAdminChat: true,
    isBacanaks: true,
  ),
  Chat.normal => const Conversation(id: 'c1', other: bob),
  Chat.group => const Conversation(id: 'c1', title: 'Team'),
};

Future<ChatFake> pumpChat(
  WidgetTester t,
  Chat c, {
  Locale locale = const Locale('en'),
  List<Message> messages = const [],
}) async {
  t.view.physicalSize = const Size(411, 891);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final chat = ChatFake(self: me.userId)
    ..conversationsResult = Ok([conv(c)])
    ..membersResult = const Ok([bob])
    ..messagesResult = Ok(messages);
  chat.history['c1'] = messages;
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: localizedApp(
        locale: locale,
        home: const MessageScreen(title: 'T'),
      ),
    ),
  );
  await t.pumpAndSettle();
  return chat;
}

Finder get field => find.descendant(
  of: byKey('composer-field'),
  matching: find.byType(EditableText),
);

Future<void> type(WidgetTester t, String s) async {
  await t.enterText(field, s);
  await t.pumpAndSettle();
}

EditableText editable(WidgetTester t) => t.widget<EditableText>(field);

void main() {
  group('matchCommands', () {
    List<String> names(String s, [List<BotCommand> all = adminCommands]) =>
        matchCommands(all, s).map((c) => c.name).toList();

    test('"/" matches every command', () {
      expect(names('/'), adminCommands.map((c) => c.name).toList());
      expect(names('/', bacanaksCommands), ['/podium']);
    });
    test('more letters narrow by prefix', () {
      expect(names('/pod'), ['/podiumon', '/podiumoff']);
      expect(names('/podiumo'), ['/podiumon', '/podiumoff']);
      expect(names('/podiumon'), ['/podiumon']);
      expect(names('/add'), ['/addiostester', '/addandroidtester']);
      expect(names('/l'), ['/listtesters']);
    });
    test('prefix only: a middle part does not match', () {
      expect(names('/tester'), isEmpty);
    });
    test('no match gives empty', () => expect(names('/zzz'), isEmpty));
    test('a space or newline ends the list', () {
      expect(names('/ '), isEmpty);
      expect(names('/podiumon '), isEmpty);
      expect(names('/addiostester a@mail.test'), isEmpty);
      expect(names('/pod\nx'), isEmpty);
    });
    test('the space rule holds even if a name could match past the space', () {
      const odd = [
        BotCommand('/a b', BotCommandKind.listTesters),
        BotCommand('/a\nb', BotCommandKind.podium),
      ];
      expect(names('/a', odd).length, 2);
      expect(names('/a ', odd), isEmpty);
      expect(names('/a\n', odd), isEmpty);
    });
    test('must start with "/"', () {
      expect(names(''), isEmpty);
      expect(names('pod'), isEmpty);
      expect(names('hi /pod'), isEmpty);
    });
    test('case-insensitive typing', () => expect(names('/POD').length, 2));
  });

  group('the command sets', () {
    test('admin has the six commands, only the first three take an email', () {
      expect(adminCommands.map((c) => c.name).toList(), [
        '/addiostester',
        '/addandroidtester',
        '/removetester',
        '/listtesters',
        '/podiumon',
        '/podiumoff',
      ]);
      expect(adminCommands.where((c) => c.takesEmail).length, 3);
    });
    test('bacanaks has /podium only', () {
      expect(bacanaksCommands.map((c) => c.name).toList(), ['/podium']);
    });
  });

  for (final (locale, l) in [
    (const Locale('en'), l10nEn),
    (const Locale('tr'), l10nTr),
  ]) {
    final lang = locale.languageCode;

    testWidgets('[$lang] CommandRow: two lines, grey email hint, label', (
      t,
    ) async {
      var taps = 0;
      final h = t.ensureSemantics();
      await t.pumpWidget(
        localizedApp(
          locale: locale,
          home: Scaffold(
            body: Column(
              children: [
                CommandRow(command: adminCommands[0], onTap: () => taps++),
                CommandRow(command: adminCommands[3], onTap: () {}),
              ],
            ),
          ),
        ),
      );
      expect(
        find.textContaining('/addiostester', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining(l.cmdArgEmail, findRichText: true),
        findsOneWidget,
        reason: 'only the email commands carry the hint',
      );
      expect(find.text(l.adminHelpIos), findsOneWidget);
      expect(find.text(l.adminHelpList), findsOneWidget);
      expect(
        find.bySemanticsLabel(l.cmdRowLabel('/listtesters', l.adminHelpList)),
        findsOneWidget,
      );
      await t.tap(find.text(l.adminHelpIos));
      expect(taps, 1);
      h.dispose();
    });

    testWidgets('[$lang] admin chat: "/" lists all six, narrows, hides', (
      t,
    ) async {
      await pumpChat(t, Chat.admin, locale: locale);
      expect(panel, findsNothing, reason: 'no list before "/"');
      await type(t, '/');
      expect(panel, findsOneWidget);
      // The card is a short scrollable list (about 196 px): scroll to each row.
      final scroller = find.descendant(
        of: panel,
        matching: find.byType(Scrollable),
      );
      final meaning = {
        '/addiostester': l.adminHelpIos,
        '/addandroidtester': l.adminHelpAnd,
        '/removetester': l.adminHelpRm,
        '/listtesters': l.adminHelpList,
        '/podiumon': l.cmdPodOnMeaning,
        '/podiumoff': l.cmdPodOffMeaning,
      };
      for (final c in adminCommands) {
        final row = find.ancestor(
          of: find.textContaining(c.name, findRichText: true),
          matching: find.byType(CommandRow),
        );
        await t.scrollUntilVisible(row, 40, scrollable: scroller);
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text(meaning[c.name]!)),
          findsOneWidget,
          reason: '${c.name}: meaning on the second line',
        );
        expect(
          find.descendant(
            of: row,
            matching: find.textContaining(l.cmdArgEmail, findRichText: true),
          ),
          c.takesEmail ? findsOneWidget : findsNothing,
          reason: '${c.name}: email hint only for email commands',
        );
      }

      await type(t, '/podiumo');
      expect(find.byType(CommandRow), findsNWidgets(2));
      await type(t, '/podiumon');
      expect(find.byType(CommandRow), findsOneWidget);
      await type(t, '/zzz');
      expect(panel, findsNothing, reason: 'no match hides the list');
      await type(t, '/');
      expect(panel, findsOneWidget);
      await type(t, '/ ');
      expect(panel, findsNothing, reason: '"/ " hides the list');
      await type(t, 'hello');
      expect(panel, findsNothing);
    });

    testWidgets('[$lang] bacanaks chat: "/" lists /podium only', (t) async {
      await pumpChat(t, Chat.bacanaks, locale: locale);
      expect(panel, findsNothing);
      await type(t, '/');
      expect(panel, findsOneWidget);
      expect(find.byType(CommandRow), findsOneWidget);
      expect(find.text('/podium'), findsOneWidget);
      expect(find.text(l.cmdPodMeaning), findsOneWidget);
      expect(
        find.text(l.cmdPodOnMeaning),
        findsNothing,
        reason: 'admin commands are not offered here',
      );
      await type(t, '/po');
      expect(find.byType(CommandRow), findsOneWidget);
      await type(t, '/x');
      expect(panel, findsNothing);
    });
  }

  group('a tap', () {
    testWidgets('fills "/name ", cursor at the end, focus, never sends', (
      t,
    ) async {
      final chat = await pumpChat(t, Chat.admin);
      await type(t, '/add');
      await t.tap(find.textContaining('/addandroidtester', findRichText: true));
      await t.pumpAndSettle();
      expect(editable(t).controller.text, '/addandroidtester ');
      expect(
        editable(t).controller.selection,
        const TextSelection.collapsed(offset: '/addandroidtester '.length),
      );
      expect(editable(t).focusNode.hasFocus, isTrue);
      expect(panel, findsNothing, reason: 'the space closes the list');
      expect(chat.sent, isEmpty, reason: 'a pick never sends');
    });

    testWidgets('bacanaks: /podium is filled, not sent', (t) async {
      final chat = await pumpChat(t, Chat.bacanaks);
      await type(t, '/');
      await t.tap(find.text('/podium'));
      await t.pumpAndSettle();
      expect(editable(t).controller.text, '/podium ');
      expect(chat.sent, isEmpty);
      expect(panel, findsNothing);
    });
  });

  group('no list', () {
    for (final c in [Chat.normal, Chat.group]) {
      testWidgets('${c.name} chat: "/" shows nothing', (t) async {
        await pumpChat(t, c);
        await type(t, '/');
        expect(panel, findsNothing);
        expect(find.byType(CommandRow), findsNothing);
        await type(t, '/pod');
        expect(panel, findsNothing);
        expect(find.byType(CommandListPanel), findsNothing);
      });
    }

    testWidgets('edit mode: no list even when the text starts with "/"', (
      t,
    ) async {
      final m = Message(
        id: 'm9',
        conversationId: 'c1',
        senderId: me.userId,
        body: '/pod',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await pumpChat(t, Chat.bacanaks, messages: [m]);
      await t.longPress(byKey('message-m9'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-edit'));
      await t.pumpAndSettle();
      expect(byKey('edit-bar'), findsOneWidget, reason: 'edit did not open');
      expect(editable(t).controller.text, '/pod');
      expect(panel, findsNothing);
      await type(t, '/');
      expect(panel, findsNothing);
    });
  });
}
