// A sent photo does not flicker (0.30.11), through the real MessageScreen,
// from the contract: once the pending bubble shows the phone's own copy
// (attachment-local), that copy stays on screen through "sent" -- never the
// network photo (attachment-image), the blurred preview (attachment-preview)
// or a loader in between -- and there is exactly one bubble, whether the
// Realtime echo or the POST answer arrives first.
//
// The server's copy of the photo is really there behind the fake, so a bubble
// that swapped to loading it would succeed in doing so and be caught here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/attach_flow.dart';
import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// What the server stores for the phone's one photo.
final row = Message(
  id: 'img-1',
  conversationId: 'c1',
  senderId: me.userId,
  body: '',
  createdAt: DateTime.now(),
  attachmentPath: 'c1/1.png',
  attachmentPreview: pngBytes,
);

Future<ChatFake> pumpChat(WidgetTester tester) async {
  final chat = ChatFake()
    ..store(row.attachmentPath!, photoPng)
    ..sendImageResult = Ok(row)
    ..holdSendImage();
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        galleryProvider.overrideWithValue(
          GalleryFake(photos: [const GalleryPhoto('p1')])
            ..thumbnails['p1'] = photoPng
            ..loadResults['p1'] = pickedPng(),
        ),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  addTearDown(container.dispose);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await settleImages(tester);
  return chat;
}

/// Every `message-...` key on screen: one bubble's worth while one photo is
/// in the conversation.
Set<String> bubbleKeys() => {
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('message-'),
          )
          .evaluate())
    (e.widget.key! as ValueKey<String>).value,
};

/// Picks the photo, sends it, and waits for the pending bubble.
Future<Set<String>> sendAndWaitForPending(WidgetTester tester) async {
  await openGrid(tester);
  await tick(tester, ['p1']);
  await sendTicked(tester);
  await tester.tap(key('preview-send'));
  for (var i = 0; i < 50 && key('attachment-local').evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(key('attachment-local'), findsOneWidget, reason: 'never pending');
  return bubbleKeys();
}

/// Runs [frames] frames -- real time included, so any load can land -- and
/// checks on every one of them that only the phone's copy is shown, in one
/// bubble.
Future<void> watch(
  WidgetTester tester,
  Set<String> oneBubble, {
  int frames = 25,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(key('attachment-local'), findsOneWidget, reason: 'frame $i');
    expect(key('attachment-image'), findsNothing, reason: 'frame $i');
    expect(key('attachment-preview'), findsNothing, reason: 'frame $i');
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'frame $i',
    );
    expect(
      bubbleKeys().length,
      oneBubble.length,
      reason: 'frame $i: ${bubbleKeys()} vs one bubble $oneBubble',
    );
  }
}

void main() {
  testWidgets('echo first, then the answer: the phone\'s copy stays, one '
      'bubble throughout', (tester) async {
    final chat = await pumpChat(tester);
    final oneBubble = await sendAndWaitForPending(tester);

    chat.deliver(row);
    await watch(tester, oneBubble);
    expect(key('message-img-1'), findsOneWidget, reason: 'echo not shown');

    chat.releaseSendImage();
    await watch(tester, oneBubble);
    expect(key('message-img-1'), findsOneWidget);
  });

  testWidgets('answer first, then the echo: the phone\'s copy stays, one '
      'bubble throughout', (tester) async {
    final chat = await pumpChat(tester);
    final oneBubble = await sendAndWaitForPending(tester);

    chat.releaseSendImage();
    await watch(tester, oneBubble);
    expect(key('message-img-1'), findsOneWidget, reason: 'answer not shown');

    chat.deliver(row);
    await watch(tester, oneBubble);
    expect(key('message-img-1'), findsOneWidget);
  });
}
