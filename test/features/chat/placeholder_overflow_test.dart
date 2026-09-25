// The "This message was deleted" placeholder and the "Forwarded" label are an
// icon and a text on one row inside a bubble. Contract: they never overflow;
// when the bubble has no room the text is shortened with an ellipsis, on one
// line. Exercised where room runs out for real: a narrow phone with the
// largest accessibility text size (x3: at x2 "Forwarded" still fits).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> _pump(WidgetTester tester, Message message) async {
  tester.view
    ..physicalSize = const Size(320, 640)
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(
          ChatFake()..messagesResult = Ok([message]),
        ),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await tester.pumpAndSettle();
}

/// [text] is laid out on one line, shortened with an ellipsis (not clipped,
/// not wrapped), and drawn entirely inside message [id]'s bubble.
void _expectEllipsizedInBubble(WidgetTester tester, String text, String id) {
  expect(tester.takeException(), isNull, reason: 'the row overflowed');

  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  expect(
    paragraph.didExceedMaxLines,
    isTrue,
    reason: '"$text" should not fit here, so it must have been shortened',
  );
  expect(paragraph.overflow, TextOverflow.ellipsis);
  final oneLine = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
    textScaler: paragraph.textScaler,
    maxLines: 1,
  )..layout();
  expect(paragraph.size.height, oneLine.height, reason: 'one line only');
  oneLine.dispose();

  final bubble = tester.getRect(find.byKey(ValueKey('message-$id')));
  final drawn = tester.getRect(find.text(text));
  expect(
    bubble.left <= drawn.left && drawn.right <= bubble.right,
    isTrue,
    reason: '"$text" at $drawn is not inside its bubble $bubble',
  );
}

void main() {
  for (final (who, from) in [
    ('my own', me.userId),
    ('a received', bob.userId),
  ]) {
    testWidgets('$who deleted message: the placeholder is ellipsized', (
      tester,
    ) async {
      await _pump(
        tester,
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: from,
          body: '',
          createdAt: DateTime.now(),
          deletion: MessageDeletion.placeholder,
        ),
      );

      expect(find.byKey(const ValueKey('deleted-m1')), findsOneWidget);
      _expectEllipsizedInBubble(tester, 'This message was deleted', 'm1');
    });

    testWidgets('$who forwarded message: the "Forwarded" label is ellipsized', (
      tester,
    ) async {
      await _pump(
        tester,
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: from,
          body: 'fyi',
          createdAt: DateTime.now(),
          forwarded: true,
        ),
      );

      expect(find.byKey(const ValueKey('forwarded-m1')), findsOneWidget);
      _expectEllipsizedInBubble(tester, 'Forwarded', 'm1');
    });
  }
}
