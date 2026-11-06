// Widget tests for deleting a message (delete rules 1-6, the S4 delete box):
// the long-press card's one Delete row opens the `delete-card` box; its
// "Also delete for NAME" (1:1) / "Delete for all members" (group) checkbox
// shows only when Message.canDeleteForEveryone allows; the media note only
// with that checkbox; a server refusal shows "Too late" and keeps the message.
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
import 'package:sis/features/chat/domain/conversation.dart';
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
  String? attachmentPath,
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: createdAt ?? DateTime.now(),
  deletion: deletion,
  attachmentPath: attachmentPath,
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
  bool listed = true,
}) async {
  // As in production, the open chat is usually on the list; [listed] false
  // is a cold start straight into the chat (e.g. from a notification).
  chat.conversationsResult = Ok([
    if (listed)
      group
          ? const Conversation(id: 'c1', title: 'Crew')
          : const Conversation(id: 'c1', other: bob),
  ]);
  final container = await _scope(chat);
  container.read(openConversationProvider.notifier).open('c1');
  // The home list under the chat keeps the list provider alive.
  container.listen(conversationListProvider, (_, _) {});
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
  // A tall history (media bubbles, day headers) can push an old bubble under
  // the app bar; a member would scroll to it first.
  await tester.ensureVisible(find.byKey(ValueKey('message-$id')));
  await tester.pumpAndSettle();
  await tester.longPress(find.byKey(ValueKey('message-$id')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('message-menu')), findsOneWidget);
}

/// Opens the box for [id]: long-press, then the card's one Delete row.
Future<void> openBox(WidgetTester tester, String id) async {
  await openCard(tester, id);
  expect(find.byKey(const ValueKey('menu-delete-for-everyone')), findsNothing);
  await tester.tap(find.byKey(const ValueKey('menu-delete-for-me')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('delete-card')), findsOneWidget);
}

Future<void> confirmBox(WidgetTester tester, {bool tick = false}) async {
  if (tick) {
    await tester.tap(find.byKey(const ValueKey('delete-also')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('delete-confirm')));
  await tester.pumpAndSettle();
}

final _ago7h = Duration(hours: 7);

/// Over 6 h old and always on the previous local day, so the day header
/// (and the taller list) shows at every hour and in every time zone.
DateTime _yesterdayOver6h() {
  final now = DateTime.now();
  final lateYesterday = DateTime(now.year, now.month, now.day, 0, -30);
  final ago7h = now.subtract(_ago7h);
  return ago7h.isBefore(lateYesterday) ? ago7h : lateYesterday;
}

const alsoBob = 'Also delete for Bob';
const allMembers = 'Delete for all members';
const mediaNote =
    "Forwarded copies and copies saved outside SIS won't be deleted.";

ChatFake groupChat({required bool admin, required List<Message> history}) =>
    ChatFake(self: me.userId)
      ..groupRosters['c1'] = [
        GroupMember(member: me, isAdmin: admin),
        GroupMember(member: bob, isAdmin: !admin),
      ]
      ..history['c1'] = history
      ..adminOf.addAll([if (admin) 'c1']);

void main() {
  group('the long-press card offers one Delete', () {
    testWidgets('own, other\'s, old: always one "Delete" row, never two', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('m1', from: me.userId, body: 'mine'),
          msg('m2', from: bob.userId, body: 'his'),
          msg(
            'm3',
            from: me.userId,
            body: 'old',
            createdAt: _yesterdayOver6h(),
          ),
        ];
      await pump(tester, chat);
      for (final id in ['m1', 'm2', 'm3']) {
        await openCard(tester, id);
        final row = find.byKey(const ValueKey('menu-delete-for-me'));
        expect(row, findsOneWidget, reason: id);
        expect(
          find.descendant(of: row, matching: find.text('Delete')),
          findsOneWidget,
          reason: '$id: the row reads "Delete"',
        );
        expect(
          find.byKey(const ValueKey('menu-delete-for-everyone')),
          findsNothing,
          reason: id,
        );
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }
    });
  });

  group('the delete box, per rule', () {
    testWidgets('1:1, own message under 6 h: "Also delete for Bob"; ticked '
        '-> deleted for everyone', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId)];
      await pump(tester, chat);
      await openBox(tester, 'm1');
      expect(find.text(alsoBob, findRichText: true), findsOneWidget);
      expect(find.text(allMembers, findRichText: true), findsNothing);
      expect(find.text(mediaNote), findsNothing, reason: 'text, no media');
      await confirmBox(tester, tick: true);
      expect(chat.deleted, ['m1']);
      expect(chat.hidden, isEmpty);
      expect(find.text('hi'), findsNothing);
    });

    testWidgets('the chat list is empty: the box names the open chat', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId)];
      await pump(tester, chat, listed: false);
      await openBox(tester, 'm1');
      expect(find.text(alsoBob, findRichText: true), findsOneWidget);
    });

    testWidgets('1:1, own message under 6 h, not ticked: hidden for me only', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId, body: 'mine')];
      await pump(tester, chat);
      await openBox(tester, 'm1');
      await confirmBox(tester);
      expect(chat.hidden, ['m1']);
      expect(chat.deleted, isEmpty);
      expect(find.text('mine'), findsNothing);
    });

    testWidgets('1:1, own message over 6 h: no checkbox, for me only', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg(
            'm1',
            from: me.userId,
            body: 'old',
            createdAt: _yesterdayOver6h(),
          ),
        ];
      await pump(tester, chat);
      await openBox(tester, 'm1');
      expect(find.byKey(const ValueKey('delete-also')), findsNothing);
      expect(find.text(alsoBob, findRichText: true), findsNothing);
      await confirmBox(tester);
      expect(chat.hidden, ['m1']);
      expect(chat.deleted, isEmpty);
    });

    testWidgets('1:1, the other person\'s message: no checkbox (rule 3)', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: bob.userId, body: 'from bob')];
      await pump(tester, chat);
      await openBox(tester, 'm1');
      expect(find.byKey(const ValueKey('delete-also')), findsNothing);
      await confirmBox(tester);
      expect(chat.hidden, ['m1']);
      expect(chat.deleted, isEmpty);
      expect(find.byKey(const ValueKey('message-m1')), findsNothing);
    });

    testWidgets(
      'group member, own message under 6 h: "Delete for all members"',
      (tester) async {
        final chat = groupChat(
          admin: false,
          history: [msg('m1', from: me.userId, body: 'mine')],
        );
        await pump(tester, chat, group: true);
        await openBox(tester, 'm1');
        expect(find.text(allMembers, findRichText: true), findsOneWidget);
        expect(find.text(alsoBob, findRichText: true), findsNothing);
        await confirmBox(tester, tick: true);
        expect(chat.deleted, ['m1']);
      },
    );

    testWidgets('group member, another\'s message: no checkbox (rule 4)', (
      tester,
    ) async {
      final chat = groupChat(
        admin: false,
        history: [msg('m1', from: bob.userId)],
      );
      await pump(tester, chat, group: true);
      await openBox(tester, 'm1');
      expect(find.byKey(const ValueKey('delete-also')), findsNothing);
      expect(find.text(allMembers, findRichText: true), findsNothing);
    });

    testWidgets('group admin, a member\'s 30-day-old message: checkbox, '
        'ticked -> deleted for everyone', (tester) async {
      final chat = groupChat(
        admin: true,
        history: [
          msg(
            'm1',
            from: bob.userId,
            body: 'from bob',
            createdAt: DateTime.now().subtract(const Duration(days: 30)),
          ),
        ],
      );
      await pump(tester, chat, group: true);
      await openBox(tester, 'm1');
      expect(find.text(allMembers, findRichText: true), findsOneWidget);
      await confirmBox(tester, tick: true);
      expect(chat.deleted, ['m1']);
      expect(find.text('from bob'), findsNothing);
    });

    testWidgets('media message: the note shows only with the checkbox', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('m1', from: me.userId, body: 'pic', attachmentPath: 'c1/1.png'),
          msg(
            'm2',
            from: me.userId,
            body: 'old pic',
            attachmentPath: 'c1/2.png',
            createdAt: _yesterdayOver6h(),
          ),
        ];
      await pump(tester, chat);

      await openBox(tester, 'm1');
      expect(find.byKey(const ValueKey('delete-also')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-also')));
      await tester.pumpAndSettle();
      expect(find.text(mediaNote), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-cancel')));
      await tester.pumpAndSettle();

      await openBox(tester, 'm2');
      expect(find.byKey(const ValueKey('delete-also')), findsNothing);
      expect(find.text(mediaNote), findsNothing);
    });

    testWidgets('cancel does nothing, ticked or not', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId)];
      await pump(tester, chat);
      for (final tick in [false, true]) {
        await openBox(tester, 'm1');
        if (tick) {
          await tester.tap(find.byKey(const ValueKey('delete-also')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('delete-cancel')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('delete-card')), findsNothing);
        expect(chat.deleted, isEmpty, reason: 'tick=$tick');
        expect(chat.hidden, isEmpty, reason: 'tick=$tick');
        expect(find.text('hi'), findsOneWidget);
      }
    });

    testWidgets('server refusal: "Too late: 6 hours have passed", message '
        'stays', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: me.userId)]
        ..deleteForEveryoneResult = const Err(DeniedFailure());
      await pump(tester, chat);
      await openBox(tester, 'm1');
      await confirmBox(tester, tick: true);
      expect(find.text('Too late: 6 hours have passed'), findsOneWidget);
      expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
      expect(chat.hidden, isEmpty, reason: 'a refusal must not hide it');
      await drainNotice(tester);
    });

    testWidgets('a confirmed delete leaves "This message was deleted"', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg(
            'm1',
            from: me.userId,
            createdAt: DateTime.now().subtract(const Duration(hours: 1)),
          ),
        ];
      await pump(tester, chat);
      await openBox(tester, 'm1');
      await confirmBox(tester, tick: true);
      expect(chat.deleted, ['m1']);
      expect(find.text('This message was deleted'), findsOneWidget);
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

  group('placeholder text', () {
    Message deleted(String by, {bool admin = false}) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: bob.userId,
      body: '',
      createdAt: DateTime.now(),
      deletion: MessageDeletion.placeholder,
      deletedBy: by,
      deletedByAdmin: admin,
    );

    testWidgets('deleted by its sender', (tester) async {
      final chat = ChatFake()..messagesResult = Ok([deleted(bob.userId)]);
      await pump(tester, chat);
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('Deleted by an admin'), findsNothing);
    });

    testWidgets('in a group the sender\'s name stays above the grey line', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..groupRosters['c1'] = [
          const GroupMember(member: me, isAdmin: false),
          const GroupMember(member: bob, isAdmin: false),
        ]
        ..messagesResult = Ok([deleted(bob.userId)]);
      await pump(tester, chat, group: true);
      expect(find.text('This message was deleted'), findsOneWidget);
      final name = find.text('Bob');
      expect(name, findsOneWidget, reason: 'title is Crew; Bob is the sender');
      expect(
        tester.getTopLeft(name).dy,
        lessThan(tester.getTopLeft(find.text('This message was deleted')).dy),
        reason: 'the name sits above the deleted line',
      );
    });

    // The line follows the server's deleted_by_admin flag alone, not who
    // deleted it: an admin deleting his OWN message after 6 h is still
    // "deleted by an admin" (rule 5), so deletedBy cannot tell.
    testWidgets('deleted by somebody else, flag not set: the plain line', (
      tester,
    ) async {
      final chat = ChatFake()..messagesResult = Ok([deleted(me.userId)]);
      await pump(tester, chat);
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('Deleted by an admin'), findsNothing);
    });

    testWidgets('admin\'s own message, flag set: "deleted by an admin"', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([deleted(bob.userId, admin: true)]);
      await pump(tester, chat);
      expect(find.text('Deleted by an admin'), findsOneWidget);
      expect(find.text('This message was deleted'), findsNothing);
    });

    testWidgets('deleted by somebody else: an admin', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([deleted(me.userId, admin: true)]);
      await pump(tester, chat);
      expect(find.text('Deleted by an admin'), findsOneWidget);
      expect(find.text('This message was deleted'), findsNothing);
    });
  });
}
