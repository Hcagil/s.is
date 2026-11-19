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
import 'package:sis/features/chat/domain/group_member.dart';
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
  void Function(ChatFake chat)? setup,
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
  setup?.call(chat);
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

/// Helper that returns a list of messages where the original is far older
/// than the newest page, so it is not loaded initially.
List<Message> oldOriginal(String replyTo) => [
  msg('m1', from: bob, body: 'first', minute: 0),
  for (var i = 1; i <= 300; i++)
    msg('f$i', from: bob, body: 'filler $i', minute: 1),
  msg('r1', body: 'sure', replyTo: replyTo, minute: 59),
];

/// Helper to configure a group conversation.
void asGroup(ChatFake chat) {
  chat.conversationsResult = const Ok([Conversation(id: 'c1', title: 'Club')]);
  chat.groupRosters['c1'] = [
    const GroupMember(member: me, isAdmin: true),
    const GroupMember(
      member: Member(userId: bob, displayName: 'Bob'),
      isAdmin: false,
    ),
  ];
}

/// Helper that checks whether the message with [id] is flashing.
bool flashing(WidgetTester tester, String id) {
  final key = find.byKey(ValueKey('message-$id'));
  final containers = <Element>[
    ...find
        .descendant(
          of: key,
          matching: find.byType(AnimatedContainer),
          matchRoot: true,
        )
        .evaluate(),
  ];
  return containers.any(
    (e) => (e.widget as AnimatedContainer).foregroundDecoration != null,
  );
}

/// Helper that returns the top-left offset of the quoted message.
Offset? replyTop(WidgetTester t) =>
    t.getTopLeft(find.byKey(const ValueKey('message-r1')));

/// The short notice runs a ~2 s timer; let it end so no Timer is pending at teardown.
Future<void> endNotice(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

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
      'tapping a quote of a message that does not exist any more: notice, no throw',
      (tester) async {
        final messages = [msg('m2', body: 'sure', replyTo: 'zz-never-loaded')];
        await pump(tester, messages);

        final quoteFinder = find.byKey(const ValueKey('quote-m2'));
        expect(quoteFinder, findsOneWidget);

        await tester.tap(quoteFinder);
        await tester.pump(); // start tap animation
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          tester.takeException(),
          isNull,
          reason: 'tapping a quote to an unloaded message should not throw',
        );
        expect(
          find.byKey(const ValueKey('quote-deleted-notice')),
          findsOneWidget,
        );
        await endNotice(tester);
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

        expect(
          flashing(tester, 'm1'),
          isFalse,
          reason: 'no highlight before the tap',
        );
        await tester.tap(quoteFinder);
        await tester.pump(); // start tap animation

        // Wait until highlight appears, up to 30 * 50ms = 1500ms
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (flashing(tester, 'm1')) break;
        }
        expect(
          flashing(tester, 'm1'),
          isTrue,
          reason: 'highlight shows after the jump',
        );

        await tester.pumpAndSettle();
        expect(
          flashing(tester, 'm1'),
          isFalse,
          reason: 'highlight cleared after settle',
        );
        expect(
          tester.binding.hasScheduledFrame,
          isFalse,
          reason: 'no frames scheduled after settle',
        );
      },
    );

    testWidgets(
      'quote of an old unloaded original (1:1): tap loads older messages, jumps and highlights',
      (tester) async {
        await pump(tester, oldOriginal('m1'));

        final quoteFinder = find.byKey(const ValueKey('quote-r1'));
        expect(quoteFinder, findsOneWidget);

        final m1Finder = find.byKey(
          const ValueKey('message-m1'),
          skipOffstage: false,
        );
        expect(m1Finder, findsNothing, reason: 'm1 not loaded initially');

        await tester.tap(quoteFinder);
        await tester.pump(); // start loading

        // Wait until m1 appears
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (m1Finder.evaluate().isNotEmpty) break;
        }
        expect(m1Finder, findsOneWidget, reason: 'm1 should appear after load');
        await tester.pump(const Duration(milliseconds: 300));
        // The animation starts on the first frame; the second pump ends it.
        await tester.pump(const Duration(milliseconds: 300));

        final screenRect =
            Offset.zero &
            (tester.view.physicalSize / tester.view.devicePixelRatio);
        final m1Rect = tester.getRect(m1Finder);
        expect(
          m1Rect.top >= 0 && m1Rect.bottom <= screenRect.height,
          isTrue,
          reason: 'm1 fully visible',
        );
        expect(flashing(tester, 'm1'), isTrue, reason: 'm1 flashing');

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'in a group: quote of an old unloaded original (1:1) loads older messages, jumps and highlights',
      (tester) async {
        await pump(tester, oldOriginal('m1'), setup: asGroup);

        final quoteFinder = find.byKey(const ValueKey('quote-r1'));
        expect(quoteFinder, findsOneWidget);

        final m1Finder = find.byKey(
          const ValueKey('message-m1'),
          skipOffstage: false,
        );
        expect(m1Finder, findsNothing, reason: 'm1 not loaded initially');

        await tester.tap(quoteFinder);
        await tester.pump(); // start loading

        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (m1Finder.evaluate().isNotEmpty) break;
        }
        expect(m1Finder, findsOneWidget, reason: 'm1 should appear after load');
        await tester.pump(const Duration(milliseconds: 300));
        // The animation starts on the first frame; the second pump ends it.
        await tester.pump(const Duration(milliseconds: 300));

        final screenRect =
            Offset.zero &
            (tester.view.physicalSize / tester.view.devicePixelRatio);
        final m1Rect = tester.getRect(m1Finder);
        expect(
          m1Rect.top >= 0 && m1Rect.bottom <= screenRect.height,
          isTrue,
          reason: 'm1 fully visible',
        );
        expect(flashing(tester, 'm1'), isTrue, reason: 'm1 flashing');

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'older fetch fails (offline): list stays where it was, no throw',
      (tester) async {
        await pump(
          tester,
          oldOriginal('m1'),
          setup: (c) =>
              c.messagesAroundResult = const Err(NetworkFailure('offline')),
        );

        final before = replyTop(tester);
        final quoteFinder = find.byKey(const ValueKey('quote-r1'));
        await tester.tap(quoteFinder);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(replyTop(tester), equals(before));
        expect(
          find.byKey(const ValueKey('message-m1'), skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets('quote of a deleted original: notice, list stays, no throw', (
      tester,
    ) async {
      await pump(tester, oldOriginal('gone-forever'));

      final before = replyTop(tester);
      final quoteFinder = find.byKey(const ValueKey('quote-r1'));
      await tester.tap(quoteFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('quote-deleted-notice')),
        findsOneWidget,
      );
      expect(replyTop(tester), equals(before));
      await endNotice(tester);
    });

    // --------------------------------------------------------------------
    // New tests added below
    // --------------------------------------------------------------------
    /// [older] messages older than the newest page; the original 'm1' is the oldest.
    /// Distinct seconds keep the order stable.
    List<Message> deepHistory(int total, String replyTo) {
      final base = DateTime.now().subtract(const Duration(hours: 5));
      return [
        for (var i = 0; i < total; i++)
          Message(
            id: i == 0 ? 'm1' : 'f$i',
            conversationId: 'c1',
            senderId: bob,
            body: i == 0 ? 'first' : 'filler $i',
            createdAt: base.add(Duration(seconds: i)),
          ),
        Message(
          id: 'r1',
          conversationId: 'c1',
          senderId: me.userId,
          body: 'sure',
          replyTo: replyTo,
          createdAt: base.add(Duration(seconds: total + 1)),
        ),
      ];
    }

    testWidgets(
      'original exactly on page 20 (1000 older messages): found, jumped, highlighted',
      (tester) async {
        await pump(tester, deepHistory(1001, 'm1'));

        final quoteFinder = find.byKey(const ValueKey('quote-r1'));
        expect(quoteFinder, findsOneWidget);

        await tester.tap(quoteFinder);
        await tester.pump(); // start loading

        final m1Finder = find.byKey(
          const ValueKey('message-m1'),
          skipOffstage: false,
        );

        // Wait until m1 appears
        for (var i = 0; i < 400; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (m1Finder.evaluate().isNotEmpty) break;
        }
        expect(m1Finder, findsOneWidget, reason: 'm1 should appear after load');
        await tester.pump(const Duration(milliseconds: 300));
        // The animation starts on the first frame; the second pump ends it.
        await tester.pump(const Duration(milliseconds: 300));

        final screenRect =
            Offset.zero &
            (tester.view.physicalSize / tester.view.devicePixelRatio);
        final m1Rect = tester.getRect(m1Finder);
        expect(
          m1Rect.top >= 0 && m1Rect.bottom <= screenRect.height,
          isTrue,
          reason: 'm1 fully visible',
        );
        expect(flashing(tester, 'm1'), isTrue, reason: 'm1 flashing');

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('original beyond page 20: no notice, no jump, no throw', (
      tester,
    ) async {
      await pump(tester, deepHistory(1100, 'm1'));

      final before = replyTop(tester);

      final quoteFinder = find.byKey(const ValueKey('quote-r1'));
      expect(quoteFinder, findsOneWidget);

      await tester.tap(quoteFinder);

      // Let the 20 pages load
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Check immediately after loop
      expect(
        find.byKey(const ValueKey('quote-deleted-notice')),
        findsNothing,
        reason: 'no notice after tap',
      );

      final m1Finder = find.byKey(
        const ValueKey('message-m1'),
        skipOffstage: false,
      );
      expect(m1Finder, findsNothing, reason: 'm1 not loaded');

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('quote-deleted-notice')),
        findsNothing,
        reason: 'no notice after settle',
      );
      expect(m1Finder, findsNothing);
      expect(replyTop(tester), equals(before));
    });
  });
}
