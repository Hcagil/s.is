// Widget tests for deleting a message for everyone: the long-press sheet,
// the confirm dialog, and how a placeholder or a vanishing message renders.
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
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

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
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  ),
);

Future<ProviderContainer> pump(WidgetTester tester, ChatFake chat) async {
  final container = await _scope(chat);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('the delete sheet', () {
    testWidgets('long-press on your own message, under 6h, opens it', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('action-delete')), findsOneWidget);
    });

    testWidgets('long-press on somebody else\'s message opens nothing', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('action-delete')), findsNothing);
    });

    testWidgets('long-press on your own message over 6h opens nothing', (
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

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('action-delete')), findsNothing);
    });

    testWidgets('cancelling the confirm dialog does nothing', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action-delete')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('delete-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-cancel')));
      await tester.pumpAndSettle();

      expect(
        chat.deleted,
        isEmpty,
        reason: 'cancelling must not call the repository',
      );
      expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
    });

    testWidgets('confirming calls the repository and updates the screen', (
      tester,
    ) async {
      // In the fake's own history, not just messagesResult: deleteForEveryone
      // (left unforced) looks a message up there to wipe it.
      final chat = ChatFake()..history['c1'] = [msg('m1', from: me.userId)];
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();

      expect(chat.deleted, ['m1']);
      // pumpAndSettle already ran the vanish animation to its end (size
      // zero), and a Finder skips an offstage/zero-size candidate by
      // default -- that IS the "takes no space" contract, so it is
      // disabled here only to prove the bubble was really replaced.
      expect(
        find.byKey(const ValueKey('vanish-m1'), skipOffstage: false),
        findsOneWidget,
      );
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

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action-delete')));
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
}
