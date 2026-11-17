// The message card and keyboard rules, driven through the real message
// screen. Written from the contract only:
//  * a long-press on a message opens the `message-menu` card (rows
//    `menu-<action>`, pin included) and closes the keyboard;
//    a tap opens no card (Update 1 slice 7); left swipe = reply;
//  * a tap on empty space only closes the keyboard; scrolling does not;
//    send keeps it open; the paperclip's Photo grid closes it, and the
//    caption page then opens with it still closed (owner report, reverses
//    0.30.10);
//  * a photo, a link or a quote keeps its own tap;
//  * the photo viewer's `viewer-menu` offers Reply, Forward and one Delete
//    exists only when the viewer was given onMenu, and closes the viewer when
//    onMenu says so.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = 'u2';

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String? attachment,
  String? replyTo,
  Uint8List? preview,
  int minute = 0,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  // Fresh, so own text is still editable.
  createdAt: DateTime.now().subtract(Duration(minutes: 60 - minute)),
  attachmentPath: attachment,
  attachmentPreview: preview,
  replyTo: replyTo,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> pump(
  WidgetTester tester,
  List<Message> messages, {
  LinkOpenerFake? opener,
  GalleryFake? gallery,
}) async {
  final chat =
      ChatFake(self: me.userId, latency: const Duration(milliseconds: 5))
        ..history['c1'] = [...messages]
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', title: 'Bob'),
          Conversation(id: 'c2', title: 'Work'),
        ]);
  for (final m in messages) {
    if (m.attachmentPath case final path?) chat.store(path);
  }
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(opener ?? LinkOpenerFake()),
        galleryProvider.overrideWithValue(gallery ?? GalleryFake()),
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
  for (final path in messages.map((m) => m.attachmentPath).nonNulls) {
    final photo = find.byKey(ValueKey('attachment-$path'));
    for (var i = 0; i < 400; i++) {
      if (photo.evaluate().isNotEmpty && !tester.getSize(photo).isEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(
      tester.getSize(photo).isEmpty,
      isFalse,
      reason: 'precondition: $path decoded and sized',
    );
  }
  await tester.pumpAndSettle();
  return container;
}

Finder get composer => find.byKey(const ValueKey('composer-field'));
Finder get menu => find.byKey(const ValueKey('message-menu'));
Finder get attach => find.byKey(const ValueKey('attach-menu'));

bool keyboardUp(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: composer, matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

Future<void> raiseKeyboard(WidgetTester tester) async {
  await tester.tap(composer);
  await tester.pumpAndSettle();
  expect(keyboardUp(tester), isTrue, reason: 'precondition: typing');
}

Finder message(String id) => find.byKey(ValueKey('message-$id'));

void main() {
  group('quote tap', () {
    testWidgets('tapping a quote scrolls the original message into view', (
      tester,
    ) async {
      final messages = <Message>[
        msg('m1', from: bob, body: 'first', minute: 0),
        for (var i = 1; i <= 40; i++)
          msg('f$i', from: bob, body: 'filler $i', minute: i),
        msg('m42', body: 'sure', replyTo: 'm1', minute: 41),
      ];
      await pump(tester, messages);

      final quoteFinder = find.byKey(const ValueKey('quote-m42'));
      expect(quoteFinder, findsOneWidget);

      final m1Finder = find.byKey(
        const ValueKey('message-m1'),
        skipOffstage: false,
      );
      final screenRect =
          Offset.zero &
          (tester.view.physicalSize / tester.view.devicePixelRatio);

      // Precondition: m1 not visible
      if (m1Finder.evaluate().isNotEmpty) {
        final m1Rect = tester.getRect(m1Finder);
        expect(
          m1Rect.overlaps(screenRect),
          isFalse,
          reason: 'm1 should not be visible before tap',
        );
      }

      await tester.tap(quoteFinder);
      await tester.pumpAndSettle();

      expect(
        m1Finder,
        findsOneWidget,
        reason: 'm1 should be in tree after tap',
      );
      final m1Rect = tester.getRect(m1Finder);
      expect(
        m1Rect.top >= 0 && m1Rect.bottom <= screenRect.height,
        isTrue,
        reason: 'm1 should be fully visible vertically',
      );
    });

    testWidgets(
      'tapping a quote of a message that was never loaded does not throw',
      (tester) async {
        final messages = [msg('m2', body: 'sure', replyTo: 'zz-never-loaded')];
        await pump(tester, messages);

        final quoteFinder = find.byKey(const ValueKey('quote-m2'));
        expect(quoteFinder, findsOneWidget);

        await tester.tap(quoteFinder);
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'tapping a quote to an unloaded message should not throw',
        );
      },
    );

    testWidgets(
      'the original flashes a highlight after the jump, then it clears',
      (tester) async {
        final messages = <Message>[
          msg('m1', from: bob, body: 'first', minute: 0),
          for (var i = 1; i <= 40; i++)
            msg('f$i', from: bob, body: 'filler $i', minute: i),
          msg('m42', body: 'sure', replyTo: 'm1', minute: 41),
        ];
        await pump(tester, messages);

        final quoteFinder = find.byKey(const ValueKey('quote-m42'));
        expect(quoteFinder, findsOneWidget);

        bool flashing() {
          final key = find.byKey(const ValueKey('message-m1'));
          final containers = <Element>[
            ...find
                .descendant(
                  of: key,
                  matching: find.byType(AnimatedContainer),
                  matchRoot: true,
                )
                .evaluate(),
            // removed ancestor spread
          ];
          return containers.any(
            (e) => (e.widget as AnimatedContainer).foregroundDecoration != null,
          );
        }

        expect(flashing(), isFalse, reason: 'no highlight before the tap');
        await tester.tap(quoteFinder);
        await tester.pump(); // start tap animation

        // Wait until highlight appears, up to 30 * 50ms = 1500ms
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (flashing()) break;
        }
        expect(flashing(), isTrue, reason: 'highlight shows after the jump');

        await tester.pumpAndSettle();
        expect(flashing(), isFalse, reason: 'highlight cleared after settle');
        expect(
          tester.binding.hasScheduledFrame,
          isFalse,
          reason: 'no frames scheduled after settle',
        );
      },
    );
  });
}
