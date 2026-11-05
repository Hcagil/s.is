// The "/" command list, from the contract:
// - the list comes from the server's staff registry (a fake here): a staff
//   chat shows the commands of its staffKey; nothing is built in.
// - matchCommands: prefix match on the name; empty unless the text starts with
//   "/" and has no space or newline yet.
// - each row has two lines (command + grey email hint, help text in the app
//   language). A tap fills "/name " and never sends.
// - no list for a normal chat, a group, an unknown staffKey, or edit mode.
// - cache first: the stored registry is used at once, without waiting for
//   the network; a refused refresh keeps it.
// Fixture words are neutral ("/report"), never real command words.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/staff_registry.dart';
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

enum Chat { staffA, staffB, unknownKey, flagOnly, normal, group }

Conversation conv(Chat c) => switch (c) {
  Chat.staffA => const Conversation(
    id: 'c1',
    title: 'x',
    isAdminChat: true,
    staffKey: 'staff_a',
  ),
  Chat.staffB => const Conversation(
    id: 'c1',
    title: 'x',
    isAdminChat: true,
    staffKey: 'staff_b',
  ),
  Chat.unknownKey => const Conversation(
    id: 'c1',
    title: 'x',
    isAdminChat: true,
    staffKey: 'staff_z',
  ),
  Chat.flagOnly => const Conversation(id: 'c1', title: 'x', isAdminChat: true),
  Chat.normal => const Conversation(id: 'c1', other: bob),
  Chat.group => const Conversation(id: 'c1', title: 'Team'),
};

final reg = neutralRegistry();
List<StaffCommand> cmds(String key) => reg.commandsFor(key);

Future<ChatFake> pumpChat(
  WidgetTester t,
  Chat c, {
  Locale locale = const Locale('en'),
  List<Message> messages = const [],
  StaffRegistryFake? staff,
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
        ...videoOverrides(
          staff: staff ?? StaffRegistryFake(stored: neutralRegistry()),
        ),
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
  group('matchCommands (from a registry)', () {
    List<String> names(String s, [String key = 'staff_a']) =>
        matchCommands(cmds(key), s).map((c) => c.name).toList();

    test('"/" matches every command of the chat, in registry order', () {
      expect(names('/'), ['/addios', '/list', '/reporton', '/reportoff']);
      expect(names('/', 'staff_b'), ['/report']);
    });
    test('more letters narrow by prefix', () {
      expect(names('/rep'), ['/reporton', '/reportoff']);
      expect(names('/reporto'), ['/reporton', '/reportoff']);
      expect(names('/reporton'), ['/reporton']);
    });
    test('prefix only: a middle part does not match', () {
      expect(names('/ios'), isEmpty);
    });
    test('no match gives empty', () => expect(names('/zzz'), isEmpty));
    test('a space or newline ends the list', () {
      expect(names('/ '), isEmpty);
      expect(names('/reporton '), isEmpty);
      expect(names('/rep\nx'), isEmpty);
    });
    test('the space rule holds even if a name could match past the space', () {
      const odd = [
        StaffCommand('/a b', 'tester_list'),
        StaffCommand('/a\nb', 'tester_list'),
      ];
      expect(matchCommands(odd, '/a').length, 2);
      expect(matchCommands(odd, '/a '), isEmpty);
      expect(matchCommands(odd, '/a\n'), isEmpty);
    });
    test('must start with "/"', () {
      expect(names(''), isEmpty);
      expect(names('rep'), isEmpty);
      expect(names('hi /rep'), isEmpty);
    });
    test('case-insensitive typing', () => expect(names('/REP').length, 2));
    test('an unknown chat key or an empty registry gives nothing', () {
      expect(names('/', 'staff_z'), isEmpty);
      expect(
        matchCommands(StaffRegistry.empty.commandsFor('staff_a'), '/'),
        isEmpty,
      );
      expect(StaffRegistry.empty.commandsFor(null), isEmpty);
    });
  });

  for (final (locale, l) in [
    (const Locale('en'), l10nEn),
    (const Locale('tr'), l10nTr),
  ]) {
    final lang = locale.languageCode;
    String help(StaffCommand c) => lang == 'tr' ? c.helpTr : c.helpEn;

    testWidgets('[$lang] CommandRow: two lines, grey email hint, server help', (
      t,
    ) async {
      var taps = 0;
      await t.pumpWidget(
        localizedApp(
          locale: locale,
          home: Scaffold(
            body: Column(
              children: [
                CommandRow(command: cmds('staff_a')[0], onTap: () => taps++),
                CommandRow(command: cmds('staff_a')[1], onTap: () {}),
              ],
            ),
          ),
        ),
      );
      expect(
        find.textContaining('/addios', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining(l.cmdArgEmail, findRichText: true),
        findsOneWidget,
        reason: 'only the email commands carry the hint',
      );
      expect(find.text(help(cmds('staff_a')[0])), findsOneWidget);
      expect(find.text(help(cmds('staff_a')[1])), findsOneWidget);
      await t.tap(find.text(help(cmds('staff_a')[0])));
      expect(taps, 1);
    });

    testWidgets(
      '[$lang] staff_a chat: "/" lists its registry commands, narrows, hides',
      (t) async {
        await pumpChat(t, Chat.staffA, locale: locale);
        expect(panel, findsNothing, reason: 'no list before "/"');
        await type(t, '/');
        expect(panel, findsOneWidget);
        final scroller = find.descendant(
          of: panel,
          matching: find.byType(Scrollable),
        );
        for (final c in cmds('staff_a')) {
          final row = find.ancestor(
            of: find.textContaining(c.name, findRichText: true),
            matching: find.byType(CommandRow),
          );
          await t.scrollUntilVisible(row.first, 40, scrollable: scroller);
          expect(
            find.descendant(of: row, matching: find.text(help(c))),
            findsOneWidget,
            reason: '${c.name}: server help on the second line',
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
        expect(
          find.text('/report'),
          findsNothing,
          reason: 'staff_b words are not offered here',
        );

        await type(t, '/reporto');
        expect(find.byType(CommandRow), findsNWidgets(2));
        await type(t, '/reporton');
        expect(find.byType(CommandRow), findsOneWidget);
        await type(t, '/zzz');
        expect(panel, findsNothing, reason: 'no match hides the list');
        await type(t, '/');
        expect(panel, findsOneWidget);
        await type(t, '/ ');
        expect(panel, findsNothing, reason: '"/ " hides the list');
        await type(t, 'hello');
        expect(panel, findsNothing);
      },
    );

    testWidgets('[$lang] staff_b chat: "/" lists /report only', (t) async {
      await pumpChat(t, Chat.staffB, locale: locale);
      await type(t, '/');
      expect(find.byType(CommandRow), findsOneWidget);
      expect(
        find.textContaining('/report', findRichText: true),
        findsOneWidget,
      );
      expect(find.text(help(cmds('staff_b')[0])), findsOneWidget);
      expect(
        find.text(help(cmds('staff_a')[2])),
        findsNothing,
        reason: 'staff_a commands are not offered here',
      );
    });
  }

  group('a tap', () {
    testWidgets('fills "/name ", cursor at the end, focus, never sends', (
      t,
    ) async {
      final chat = await pumpChat(t, Chat.staffA);
      await type(t, '/add');
      await t.tap(find.text('Add a phone tester'));
      await t.pumpAndSettle();
      expect(editable(t).controller.text, '/addios ');
      expect(
        editable(t).controller.selection,
        const TextSelection.collapsed(offset: 8),
      );
      expect(editable(t).focusNode.hasFocus, isTrue);
      expect(panel, findsNothing, reason: 'the space closes the list');
      expect(chat.sent, isEmpty, reason: 'a pick never sends');
    });
  });

  group('cache first', () {
    testWidgets('the stored registry is used while the network hangs', (
      t,
    ) async {
      final staff = StaffRegistryFake(stored: neutralRegistry())
        ..refreshGate = Completer<void>();
      await pumpChat(t, Chat.staffB, staff: staff);
      await type(t, '/');
      expect(find.byType(CommandRow), findsOneWidget);
      expect(
        staff.refreshCalls,
        1,
        reason: 'a refresh was asked for, and still hangs',
      );
    });

    testWidgets('no stored registry: the server answer fills the list', (
      t,
    ) async {
      final staff = StaffRegistryFake(refreshResult: Ok(neutralRegistry()));
      await pumpChat(t, Chat.staffB, staff: staff);
      await type(t, '/');
      expect(find.byType(CommandRow), findsOneWidget);
    });

    testWidgets('a refused refresh keeps the stored registry', (t) async {
      final staff = StaffRegistryFake(
        stored: neutralRegistry(),
        refreshResult: const Err(NetworkFailure('offline')),
      );
      await pumpChat(t, Chat.staffB, staff: staff);
      await type(t, '/');
      expect(find.byType(CommandRow), findsOneWidget);
    });

    testWidgets('an empty server answer replaces the stored list', (t) async {
      final staff = StaffRegistryFake(
        stored: neutralRegistry(),
        refreshResult: const Ok(StaffRegistry.empty),
      );
      await pumpChat(t, Chat.staffB, staff: staff);
      await type(t, '/');
      expect(
        panel,
        findsNothing,
        reason: 'a removed member keeps no stale list',
      );
    });
  });

  group('no list', () {
    for (final c in [Chat.normal, Chat.group, Chat.unknownKey, Chat.flagOnly]) {
      testWidgets('${c.name} chat: "/" shows nothing', (t) async {
        await pumpChat(t, c);
        await type(t, '/');
        expect(panel, findsNothing);
        expect(find.byType(CommandRow), findsNothing);
        await type(t, '/rep');
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
        body: '/rep',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await pumpChat(t, Chat.staffB, messages: [m]);
      await t.longPress(byKey('message-m9'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-edit'));
      await t.pumpAndSettle();
      expect(byKey('edit-bar'), findsOneWidget, reason: 'edit did not open');
      expect(editable(t).controller.text, '/rep');
      expect(panel, findsNothing);
      await type(t, '/');
      expect(panel, findsNothing);
    });
  });
}
