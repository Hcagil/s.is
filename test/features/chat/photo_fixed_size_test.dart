// A photo sent without a preview (every bot photo) keeps one 240x240 box in
// every state, so the reversed message list never shifts when its bytes
// arrive. A photo with a preview still takes its size from the preview.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const fixed = Size(240, 240);

/// A 2x1 PNG: a preview twice as wide as it is tall.
final widePreview = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4z8AARAAI/gH/xp559wAAAABJRU5ErkJggg==',
);

Message photo(String id, int minute, {Uint8List? preview}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: '',
  createdAt: DateTime.utc(2026, 9, 22, 12, minute),
  attachmentPath: 'c1/$id.png',
  attachmentPreview: preview,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

ChatFake chatWith(List<Message> messages) {
  final chat = ChatFake(latency: const Duration(milliseconds: 5))
    ..messagesResult = Ok(messages);
  for (final m in messages) {
    chat.store(m.attachmentPath!);
  }
  return chat;
}

Future<void> pump(
  WidgetTester tester,
  ChatFake chat, {
  bool decode = true,
  bool gateOpen = true,
}) async {
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        if (!gateOpen)
          photoGateProvider.overrideWith((ref, path) async => false),
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
  if (decode) await settleImages(tester);
}

Finder box(String id) => find.byKey(ValueKey('attachment-c1/$id.png'));

void main() {
  setUpAll(() => HttpOverrides.global = ImageServer());
  tearDownAll(() => HttpOverrides.global = null);
  setUp(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  group('a photo without a preview', () {
    testWidgets('is 240x240 while loading and still 240x240 once loaded', (
      tester,
    ) async {
      final chat = chatWith([photo('m1', 1)])..holdBytes();
      await pump(tester, chat, decode: false);
      expect(chat.bytesRequests, contains('c1/m1.png'));
      expect(tester.getSize(box('m1')), fixed, reason: 'loading');

      chat.releaseBytes();
      await settleImages(tester);
      await tester.pump();
      expect(
        find.descendant(of: box('m1'), matching: find.byType(Image)),
        findsWidgets,
        reason: 'this step is about the loaded photo',
      );
      expect(tester.getSize(box('m1')), fixed, reason: 'loaded');
    });

    testWidgets('a loaded photo fills its box with cover', (tester) async {
      await pump(tester, chatWith([photo('m1', 1)]));
      final images = tester.widgetList<Image>(
        find.descendant(of: box('m1'), matching: find.byType(Image)),
      );
      expect(images.map((i) => i.fit), contains(BoxFit.cover));
    });

    testWidgets('is 240x240 before the download is allowed (placeholder)', (
      tester,
    ) async {
      final chat = chatWith([photo('m1', 1)]);
      await pump(tester, chat, gateOpen: false, decode: false);
      expect(chat.bytesRequests, isNot(contains('c1/m1.png')));
      expect(tester.getSize(box('m1')), fixed);
    });

    testWidgets('is 240x240 when its bytes cannot be fetched', (tester) async {
      final chat = chatWith([photo('m1', 1)]);
      chat.bytesFailures['c1/m1.png'] = const NetworkFailure('refused');
      await pump(tester, chat);
      expect(chat.bytesRequests, contains('c1/m1.png'));
      expect(tester.getSize(box('m1')), fixed);
    });

    testWidgets('is 240x240 when its bytes are not an image', (tester) async {
      final chat = chatWith([photo('m1', 1)])
        ..store('c1/m1.png', Uint8List.fromList([1, 2, 3, 4]));
      await pump(tester, chat);
      expect(tester.getSize(box('m1')), fixed);
    });

    testWidgets('a tap still opens the photo viewer', (tester) async {
      await pump(tester, chatWith([photo('m1', 1)]));
      await tester.tap(box('m1'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
    });
  });

  testWidgets('a photo with a preview still takes its shape from it', (
    tester,
  ) async {
    await pump(tester, chatWith([photo('m1', 1, preview: widePreview)]));
    final size = tester.getSize(box('m1'));
    expect(size, isNot(fixed));
    expect(
      size.width / size.height,
      closeTo(2, 0.05),
      reason: 'the preview is twice as wide as tall',
    );
  });

  testWidgets(
    'scrolled up in a long chat, photos finishing their loads move nothing',
    (tester) async {
      final chat = chatWith([for (var i = 1; i <= 8; i++) photo('m$i', i)])
        ..holdBytes();
      await pump(tester, chat, decode: false);

      final list = find
          .ancestor(of: box('m8'), matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(list);
      await tester.drag(list, const Offset(0, 300));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final visible = [
        for (var i = 1; i <= 8; i++)
          if (box('m$i').evaluate().isNotEmpty) 'm$i',
      ];
      expect(visible, isNotEmpty);
      final before = {for (final id in visible) id: tester.getTopLeft(box(id))};
      final offset = scroll.position.pixels;
      expect(offset, greaterThan(0), reason: 'the list must be scrolled');

      chat.releaseBytes();
      await settleImages(tester);
      await tester.pump();

      expect(
        scroll.position.pixels,
        offset,
        reason: 'the scroll offset must not change',
      );
      for (final id in visible) {
        expect(tester.getTopLeft(box(id)), before[id], reason: '$id moved');
      }
    },
  );
}
