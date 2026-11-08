// Small photo first, written from the contract: a photo bubble and an album
// grid cell load the small copy (attachmentThumbProvider) and never the full
// file while a small copy exists; a tap opens the viewer, which loads the full
// file. Wired as production mounts MessageScreen, over ChatFake.
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
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Message photo(String id, {String? group, int minute = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: '',
  createdAt: DateTime.now().subtract(Duration(minutes: 60 - minute)),
  attachmentPath: 'c1/$id.png',
  photoGroup: group,
);

Future<ChatFake> pump(
  WidgetTester tester,
  List<Message> messages, {
  bool withSmall = true,
}) async {
  final chat =
      ChatFake(self: me.userId, latency: const Duration(milliseconds: 5))
        ..history['c1'] = [...messages]
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', title: 'Bob'),
        ]);
  for (final m in messages) {
    chat.store(m.attachmentPath!);
    if (withSmall) chat.thumbBytes[m.attachmentPath!] = pngBytes;
  }
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
        galleryProvider.overrideWithValue(GalleryFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(Brightness.light),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await settleImages(tester);
  await tester.pumpAndSettle();
  return chat;
}

void main() {
  setUp(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  testWidgets('a photo bubble loads the small copy, not the full file', (
    tester,
  ) async {
    final chat = await pump(tester, [photo('m1')]);

    expect(chat.thumbRequests, contains('c1/m1.png'));
    expect(chat.bytesRequests, isNot(contains('c1/m1.png')));
  });

  testWidgets('a tap opens the viewer, which loads the full file', (
    tester,
  ) async {
    final chat = await pump(tester, [photo('m1')]);
    final thumbsBefore = chat.thumbRequests.length;

    await tester.tap(find.byKey(const ValueKey('attachment-c1/m1.png')));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(chat.bytesRequests, ['c1/m1.png']);
    expect(
      chat.thumbRequests.length,
      thumbsBefore,
      reason: 'the viewer asks for the full photo, not the small copy',
    );
  });

  testWidgets('an old photo with no small copy shows the full file', (
    tester,
  ) async {
    final chat = await pump(tester, [photo('m1')], withSmall: false);

    expect(chat.thumbRequests, contains('c1/m1.png'));
    expect(chat.bytesRequests, contains('c1/m1.png'));
  });

  testWidgets('album grid cells load the small copies only', (tester) async {
    final chat = await pump(tester, [
      for (var i = 1; i <= 3; i++) photo('p$i', group: 'g1', minute: i),
    ]);

    expect(
      chat.thumbRequests,
      containsAll(['c1/p1.png', 'c1/p2.png', 'c1/p3.png']),
    );
    expect(chat.bytesRequests.where((p) => p.startsWith('c1/p')), isEmpty);
  });
}
