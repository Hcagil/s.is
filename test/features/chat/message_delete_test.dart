// Widget tests for deleting a message: the long-press card's delete for me
// and delete for everyone rows, the `delete-card` confirm card, and how a placeholder or a vanishing message renders.
// Written from the contract: what a member sees and what the repository is
// asked to do -- never how the widgets are built.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String conversation = 'c1',
  DateTime? createdAt,
  MessageDeletion? deletion,
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: createdAt ?? DateTime.now(),
  deletion: deletion,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> _scope(ChatFake chat) => settled(
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

Future<ProviderContainer> pump(
  WidgetTester tester,
  ChatFake chat, {
  bool group = false,
}) async {
  final container = await _scope(chat);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessageScreen(title: group ? 'Crew' : 'Bob', group: group),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Long-presses message [id]: the action card opens.
Future<void> openCard(WidgetTester tester, String id) async {
  await tester.longPress(find.byKey(ValueKey('message-$id')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('message-menu')), findsOneWidget);
}

void main() {
  group('delete from the long-press card', () {
    testWidgets('your own message, under 6h: both deletes offered', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId)]);
      await pump(tester, chat);

      await openCard(tester, 'm1');

      expect(find.byKey(const ValueKey('menu-delete-for-me')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('menu-delete-for-everyone')),
        findsOneWidget,
      );
    });

    testWidgets('somebody else\'s message offers delete for me only', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId)]);
      await pump(tester, chat);

      await openCard(tester, 'm1');

      expect(
        find.byKey(const ValueKey('menu-reply')),
        findsOneWidget,
        reason: 'the card did open',
      );
      expect(find.byKey(const ValueKey('menu-delete-for-me')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('menu-delete-for-everyone')),
        findsNothing,
      );
    });

    testWidgets('your own message over 6h still offers delete for everyone', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([
          msg(
            'm1',
            from: me.userId,
            createdAt: DateTime.now().subtract(const Duration(hours: 7)),
          ),
        ]);
      await pump(tester, chat);

      await openCard(tester, 'm1');

      expect(
        find.byKey(const ValueKey('menu-reply')),
        findsOneWidget,
        reason: 'the card did open',
      );
      expect(
        find.byKey(const ValueKey('menu-delete-for-everyone')),
        findsOneWidget,
        reason: 'since 0.30.8 the sender may delete at any age',
      );
    });

    testWidgets('cancelling the confirm card does nothing', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId)];
      await pump(tester, chat);

      for (final row in ['delete-for-everyone', 'delete-for-me']) {
        await openCard(tester, 'm1');
        await tester.tap(find.byKey(ValueKey('menu-$row')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('delete-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('delete-confirm')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('delete-cancel')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('delete-card')), findsNothing);
        expect(
          chat.deleted,
          isEmpty,
          reason: '$row: cancelling must not call the repository',
        );
        expect(chat.hidden, isEmpty, reason: row);
        expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
        expect(find.text('hi'), findsOneWidget);
      }
    });

    testWidgets('confirming calls the repository and updates the screen', (
      tester,
    ) async {
      // In the fake's own history, not just messagesResult: deleteForEveryone
      // (left unforced) looks a message up there to wipe it.
      final chat = ChatFake()..history['c1'] = [msg('m1', from: me.userId)];
      await pump(tester, chat);

      await openCard(tester, 'm1');
      await tester.tap(find.byKey(const ValueKey('menu-delete-for-everyone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();

      expect(chat.deleted, ['m1']);
      expect(chat.hidden, isEmpty);
      expect(
        find.text('This message was deleted'),
        findsOneWidget,
        reason: 'since 0.30.8 every delete leaves a placeholder',
      );
      expect(find.text('hi'), findsNothing);
    });

    testWidgets('a refusal shows its reason and leaves the message shown', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId)])
        ..deleteForEveryoneResult = const Err(
          ProviderFailure('too late for that'),
        );
      await pump(tester, chat);

      await openCard(tester, 'm1');
      await tester.tap(find.byKey(const ValueKey('menu-delete-for-everyone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('too late for that'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('vanish-m1')),
        findsNothing,
        reason: 'a refused delete must not touch the message',
      );
      expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
      await drainNotice(tester);
    });
  });

  group('a deletion arriving live', () {
    testWidgets('a placeholder bubble shows "This message was deleted"', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId)]);
      await pump(tester, chat);

      chat.deliver(
        msg(
          'm1',
          from: bob.userId,
          body: '',
          deletion: MessageDeletion.placeholder,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('deleted-m1')), findsOneWidget);
      expect(find.text('This message was deleted'), findsOneWidget);
    });

    testWidgets('a vanishing message animates away and ends taking no space', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId, body: 'oops')]);
      await pump(tester, chat);

      chat.deliver(
        msg(
          'm1',
          from: bob.userId,
          body: '',
          deletion: MessageDeletion.vanished,
        ),
      );
      // A single frame in: the deletion has reached the controller and the
      // wrapper is in the tree, but the 350ms animation has not run yet,
      // so the bubble is still full size and found by the default finder.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final vanishing = find.byKey(
        const ValueKey('vanish-m1'),
        skipOffstage: false,
      );
      expect(vanishing, findsOneWidget);
      expect(
        tester.getSize(vanishing).height,
        greaterThan(1),
        reason: 'right after the deletion arrives, the bubble is still shown',
      );

      await tester.pumpAndSettle();

      // The default finder skips an offstage/zero-size candidate, which
      // the animation has now made this one -- exactly the point being
      // proved, so it is disabled to reach it for the size check itself.
      expect(
        tester.getSize(vanishing).height,
        lessThan(1),
        reason: 'once vanished, the bubble must take no visible space',
      );
    });
  });

  group('delete for me and group admins (0.30.8)', () {
    Future<void> confirm(WidgetTester tester, String id, String row) async {
      await openCard(tester, id);
      await tester.tap(find.byKey(ValueKey('menu-$row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-card')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
    }

    testWidgets('your own message, delete for me: hidden here only', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId, body: 'mine')];
      await pump(tester, chat);
      await confirm(tester, 'm1', 'delete-for-me');

      expect(chat.hidden, ['m1']);
      expect(chat.deleted, isEmpty);
      expect(find.text('mine'), findsNothing);
    });

    testWidgets('somebody else\'s message: for me only, and it hides it', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: bob.userId, body: 'from bob')];
      await pump(tester, chat);
      await confirm(tester, 'm1', 'delete-for-me');

      expect(chat.hidden, ['m1']);
      expect(chat.deleted, isEmpty);
      expect(find.text('from bob'), findsNothing);
      expect(find.byKey(const ValueKey('message-m1')), findsNothing);
    });

    testWidgets('a group admin may delete a member\'s message for everyone', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..adminOf.add('c1')
        ..groupRosters['c1'] = [
          const GroupMember(member: me, isAdmin: true),
          const GroupMember(member: bob, isAdmin: false),
        ]
        ..history['c1'] = [
          msg(
            'm1',
            from: bob.userId,
            body: 'from bob',
            createdAt: DateTime.now().subtract(const Duration(days: 30)),
          ),
        ];
      await pump(tester, chat, group: true);
      await confirm(tester, 'm1', 'delete-for-everyone');

      expect(chat.deleted, ['m1']);
      expect(find.text('from bob'), findsNothing);
      expect(find.text('Deleted by an admin'), findsOneWidget);
    });

    testWidgets(
      'a member who is not admin gets no for-everyone on another\'s',
      (tester) async {
        final chat = ChatFake(self: me.userId)
          ..groupRosters['c1'] = [
            const GroupMember(member: me, isAdmin: false),
            const GroupMember(member: bob, isAdmin: true),
          ]
          ..history['c1'] = [msg('m1', from: bob.userId)];
        await pump(tester, chat, group: true);
        await openCard(tester, 'm1');

        expect(
          find.byKey(const ValueKey('menu-delete-for-me')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('menu-delete-for-everyone')),
          findsNothing,
        );
      },
    );
  });

  group('placeholder text', () {
    Message deleted(String by) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: bob.userId,
      body: '',
      createdAt: DateTime.now(),
      deletion: MessageDeletion.placeholder,
      deletedBy: by,
    );

    testWidgets('deleted by its sender', (tester) async {
      final chat = ChatFake()..messagesResult = Ok([deleted(bob.userId)]);
      await pump(tester, chat);
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('Deleted by an admin'), findsNothing);
    });

    testWidgets('deleted by somebody else: an admin', (tester) async {
      final chat = ChatFake()..messagesResult = Ok([deleted(me.userId)]);
      await pump(tester, chat);
      expect(find.text('Deleted by an admin'), findsOneWidget);
      expect(find.text('This message was deleted'), findsNothing);
    });
  });
}
