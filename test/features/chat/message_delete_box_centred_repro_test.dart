import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

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

void main() {
  final List<Map<String, dynamic>> sizes = [
    {'name': '390x844', 'w': 390.0, 'h': 844.0},
    {'name': '360x800', 'w': 360.0, 'h': 800.0},
  ];
  final List<Map<String, dynamic>> cases = [
    {'label': 'received', 'from': 'u2'},
    {'label': 'own', 'from': 'u1'},
  ];

  for (final size in sizes) {
    for (final c in cases) {
      testWidgets(
        'delete box is centred and on screen: ${c['label']} message at ${size['name']}',
        (tester) async {
          tester.view.physicalSize = Size(size['w']! * 3, size['h']! * 3);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);

          final chat = ChatFake(self: me.userId)
            ..history['c1'] = [msg('m1', from: c['from']!, body: 'hello')];

          await pump(tester, chat);
          await openBox(tester, 'm1');

          final r = tester.getRect(find.byKey(const ValueKey('delete-card')));
          final screen = Offset.zero & Size(size['w']!, size['h']!);
          final reason = 'dialog rect $r, screen $screen';

          expect(
            (r.center.dx - size['w']! / 2).abs() < 4,
            isTrue,
            reason: reason,
          );
          expect(
            screen.contains(r.topLeft) && screen.contains(r.bottomRight),
            isTrue,
            reason: reason,
          );
        },
      );
    }
  }
}
