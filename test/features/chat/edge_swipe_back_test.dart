// Swiping from the left edge goes back (0.30.11), on iOS and Android alike,
// from the contract: a drag that starts within 15 px of the left edge pops
// the chat -- also when it starts over a bubble -- while a drag that starts
// 30 px or more in, on a bubble, opens that bubble's actions instead. Every
// 0.30.10 full-screen page (forward, new chat, new group, add members,
// attachment preview) pops on the same edge swipe.
//
// Mounted the way production mounts it: the app's own theme (sisTheme),
// the chat opened through openConversation, each page through its own
// show* function. Android has no edge swipe of its own: only the theme's
// page transition can give it one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/add_members_page.dart';
import 'package:sis/features/chat/presentation/attachment_preview_page.dart';
import 'package:sis/features/chat/presentation/forward_page.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/new_chat_page.dart';
import 'package:sis/features/chat/presentation/new_group_page.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

final platforms = TargetPlatformVariant.only(TargetPlatform.android)
  ..values.add(TargetPlatform.iOS);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final fromBob = Message(
  id: 'm1',
  conversationId: 'c1',
  senderId: bob.userId,
  body: 'a message from bob, long enough to span a good part of the row',
  createdAt: DateTime.now(),
);

ChatFake chat() => ChatFake(self: me.userId)
  ..history['c1'] = [fromBob]
  ..roster['c1'] = [me, bob, cem]
  ..membersResult = const Ok([bob, cem])
  ..conversationsResult = const Ok([
    Conversation(id: 'c1', title: 'Bob'),
    Conversation(id: 'c2', title: 'Work'),
  ]);

/// Pumps the app's theme around a launcher page; [launch] opens whatever is
/// under test from it. Returns the container.
Future<ProviderContainer> pumpLauncher(
  WidgetTester tester,
  void Function(BuildContext context, WidgetRef ref) launch,
) async {
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      ],
    ),
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('launch'),
                onPressed: () => launch(context, ref),
                child: const Text('launch'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('launch')));
  await settleImages(tester);
  return container;
}

/// A finger put down at [from] and drawn most of the way across the screen.
Future<void> swipeRight(WidgetTester tester, Offset from) async {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final g = await tester.startGesture(from);
  for (var i = 0; i < 12; i++) {
    await g.moveBy(Offset(width * 0.06, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await settleImages(tester);
}

double midHeight(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio / 2;

Finder bubble(String id) => find.byKey(ValueKey('message-$id'));

Future<ProviderContainer> openChat(WidgetTester tester) async {
  final c = await pumpLauncher(
    tester,
    (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
  );
  expect(find.byType(MessageScreen), findsOneWidget);
  expect(bubble('m1'), findsOneWidget);
  return c;
}

void main() {
  group('the chat', () {
    testWidgets('a drag from the left edge pops it', (tester) async {
      final c = await openChat(tester);

      await swipeRight(tester, Offset(5, midHeight(tester)));

      expect(find.byType(MessageScreen), findsNothing);
      expect(find.byKey(const ValueKey('launch')), findsOneWidget);
      expect(c.read(openConversationProvider), isNull, reason: 'not closed');
    }, variant: platforms);

    testWidgets('a drag from the left edge over a bubble pops it, and opens '
        'no actions', (tester) async {
      await openChat(tester);
      final y = tester.getCenter(bubble('m1')).dy;
      final rect = tester.getRect(bubble('m1'));
      expect(rect.top < y && y < rect.bottom, isTrue);

      await swipeRight(tester, Offset(10, y));

      expect(find.byType(MessageScreen), findsNothing);
      expect(find.byKey(const ValueKey('swipe-actions-m1')), findsNothing);
    }, variant: platforms);

    testWidgets('a drag from 30 px in, on a bubble, opens its actions and '
        'stays in the chat', (tester) async {
      await openChat(tester);
      final rect = tester.getRect(bubble('m1'));
      final x = rect.left + 2 > 30 ? rect.left + 2 : 30.0;
      expect(rect.contains(Offset(x, rect.center.dy)), isTrue);

      await tester.dragFrom(Offset(x, rect.center.dy), swipeOpen);
      await settleImages(tester);

      expect(find.byType(MessageScreen), findsOneWidget, reason: 'popped');
      expect(find.byKey(const ValueKey('swipe-actions-m1')), findsOneWidget);
    }, variant: platforms);
  });

  group('every full-screen page pops on an edge swipe', () {
    final pages = <String, (Type, void Function(BuildContext, WidgetRef))>{
      'forward': (
        ForwardPage,
        (context, ref) => showForwardPage(context, ref, fromBob),
      ),
      'new chat': (NewChatPage, (context, _) => showNewChatPage(context)),
      'new group': (NewGroupPage, (context, _) => showNewGroupPage(context)),
      'add members': (
        AddMembersPage,
        (context, ref) => showAddMembersPage(
          context,
          ref,
          'c1',
          current: {me.userId, bob.userId},
          groupTitle: 'Team',
        ),
      ),
      'attachment preview': (
        AttachmentPreviewPage,
        (context, _) => showAttachmentPreview(context, images: [pickedPng()]),
      ),
    };

    for (final MapEntry(key: name, value: (type, launch)) in pages.entries) {
      testWidgets(name, (tester) async {
        await pumpLauncher(tester, launch);
        expect(find.byType(type), findsOneWidget, reason: 'never opened');

        await swipeRight(tester, Offset(5, midHeight(tester)));

        expect(find.byType(type), findsNothing, reason: 'still open');
        expect(find.byKey(const ValueKey('launch')), findsOneWidget);
      }, variant: platforms);
    }
  });
}
