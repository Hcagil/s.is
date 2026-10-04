// The 0.30.8 message menu and keyboard rules, driven through the real
// message screen. Written from the contract only:
//  * a tap on a message opens the `message-menu` sheet (tiles `menu-<action>`),
//    closes the keyboard (0.30.13: the swipe row is gone, left = reply);
//  * a tap on empty space only closes the keyboard; scrolling does not;
//    send and the paperclip keep it open (0.30.10: the paperclip opens the
//    photo grid with requestFocus false);
//  * long-press opens nothing;
//  * a photo, a link or a quote keeps its own tap;
//  * your own stored message offers read-by first, in every chat;
//  * the photo viewer's `viewer-menu` offers Reply, Forward and Delete only
//    (never read-by),
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
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = 'u2';

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String? attachment,
  String? replyTo,
  int minute = 0,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  // Fresh, so own text is still editable.
  createdAt: DateTime.now().subtract(Duration(minutes: 60 - minute)),
  attachmentPath: attachment,
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
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(opener ?? LinkOpenerFake()),
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
  return container;
}

Finder get composer => find.byKey(const ValueKey('composer-field'));
Finder get menu => find.byKey(const ValueKey('message-menu'));

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

List<String> menuTiles(WidgetTester tester) {
  final tiles = find
      .descendant(
        of: menu,
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('menu-'),
        ),
      )
      .evaluate()
      .map((e) => e.widget.key! as ValueKey<String>)
      .toList();
  final byTop = [
    for (final k in tiles) (k.value, tester.getTopLeft(find.byKey(k)).dy),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final t in byTop) t.$1.substring('menu-'.length)];
}

void main() {
  group('a tap on a message', () {
    testWidgets('opens the menu: your own fresh text, in order', (
      tester,
    ) async {
      await pump(tester, [msg('m1')]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();

      expect(menu, findsOneWidget);
      // A 1:1: read-by first, as in a group.
      expect(menuTiles(tester), [
        'read-by',
        'reply',
        'copy',
        'forward',
        'edit',
        'delete',
      ]);
    });

    testWidgets('somebody else\'s text: no edit, delete (for me) stays', (
      tester,
    ) async {
      await pump(tester, [msg('m1', from: bob)]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      expect(menuTiles(tester), ['reply', 'copy', 'forward', 'delete']);
    });

    testWidgets('closes the keyboard', (tester) async {
      await pump(tester, [msg('m1', from: bob)]);
      await raiseKeyboard(tester);

      await tester.tap(message('m1'));
      await tester.pumpAndSettle();

      expect(menu, findsOneWidget);
      expect(keyboardUp(tester), isFalse);
    });

    // 0.30.13: the swipe row is gone; a left swipe replies and opens no
    // card, and the tap that follows still opens it.
    testWidgets('a left swipe opens no card; a tap after it does', (
      tester,
    ) async {
      await pump(tester, [
        msg('m1', from: bob),
        msg('m2', from: bob, minute: 1),
      ]);
      await tester.drag(message('m1'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);

      await tester.tap(message('m2'));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
    });

    testWidgets('menu-reply starts a reply to that message', (tester) async {
      await pump(tester, [msg('m1', from: bob, body: 'lunch?')]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();

      expect(menu, findsNothing);
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
    });

    testWidgets('long-press opens nothing', (tester) async {
      await pump(tester, [msg('m1', from: bob)]);
      await tester.longPress(message('m1'));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('the keyboard', () {
    testWidgets('a tap on empty space closes it and opens nothing', (
      tester,
    ) async {
      await pump(tester, [msg('m1', from: bob)]);
      await raiseKeyboard(tester);

      final list = tester.getRect(
        find
            .ancestor(of: message('m1'), matching: find.byType(Scrollable))
            .first,
      );
      final bubble = tester.getRect(message('m1'));
      // Above the only message, inside the list: nothing there.
      expect(bubble.top - list.top, greaterThan(40), reason: 'room to tap');
      await tester.tapAt(Offset(list.center.dx, list.top + 20));
      await tester.pumpAndSettle();

      expect(keyboardUp(tester), isFalse);
      expect(menu, findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('scrolling the messages leaves it up', (tester) async {
      await pump(tester, [
        for (var i = 0; i < 40; i++)
          msg('m$i', from: bob, body: 'line $i', minute: i),
      ]);
      await raiseKeyboard(tester);

      final list = find
          .ancestor(of: message('m39'), matching: find.byType(Scrollable))
          .first;
      await tester.drag(list, const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(keyboardUp(tester), isTrue);
      expect(menu, findsNothing);
    });

    testWidgets('send leaves it up', (tester) async {
      await pump(tester, [msg('m1', from: bob)]);
      await raiseKeyboard(tester);
      await tester.enterText(composer, 'hello');
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(keyboardUp(tester), isTrue);
    });

    testWidgets('the paperclip leaves it up', (tester) async {
      await pump(tester, [msg('m1', from: bob)]);
      await raiseKeyboard(tester);
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();

      // 0.30.10: the paperclip opens the photo grid itself.
      expect(find.text('Recent photos'), findsOneWidget);
      expect(find.byKey(const ValueKey('sheet-from-app')), findsOneWidget);
      expect(keyboardUp(tester), isTrue);
    });
  });

  group('taps that keep their own meaning', () {
    testWidgets('a link opens, no menu', (tester) async {
      final opener = LinkOpenerFake();
      await pump(tester, [
        msg('m1', from: bob, body: 'see https://example.com'),
      ], opener: opener);
      await tester.tapOnText(
        find.textRange.ofSubstring(
          'https://example.com',
          descendentOf: find.byKey(const ValueKey('body-m1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(opener.opened, hasLength(1));
      expect(menu, findsNothing);
    });

    testWidgets('a photo opens the viewer, no menu', (tester) async {
      await pump(tester, [
        msg('p1', from: bob, body: '', attachment: 'c1/1.png'),
      ]);
      await tester.tap(find.byKey(const ValueKey('attachment-c1/1.png')));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(menu, findsNothing);
    });

    testWidgets('a quote does not open the menu', (tester) async {
      await pump(tester, [
        msg('m1', from: bob, body: 'lunch?'),
        msg('m2', body: 'sure', replyTo: 'm1', minute: 1),
      ]);
      expect(find.byKey(const ValueKey('quote-m2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quote-m2')));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
    });
  });

  group('the photo viewer menu', () {
    Future<void> openViewer(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('attachment-c1/1.png')));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
    }

    testWidgets('offers reply, forward and delete only', (tester) async {
      await pump(tester, [msg('p1', body: 'caption', attachment: 'c1/1.png')]);
      await openViewer(tester);
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();

      expect(menu, findsOneWidget);
      expect(menuTiles(tester), ['reply', 'forward', 'delete']);
    });

    testWidgets('reply closes the viewer and starts the reply', (tester) async {
      await pump(tester, [
        msg('p1', from: bob, body: '', attachment: 'c1/1.png'),
      ]);
      await openViewer(tester);
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();

      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
    });

    Future<void> standalone(WidgetTester tester, PhotoMenu? onMenu) async {
      final container = await pump(tester, [
        msg('p1', from: bob, body: '', attachment: 'c1/1.png'),
      ]);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => UncontrolledProviderScope(
            container: container,
            child: PhotoViewer(paths: const ['c1/1.png'], onMenu: onMenu),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
    }

    testWidgets('no onMenu, no menu button', (tester) async {
      await standalone(tester, null);
      expect(find.byKey(const ValueKey('viewer-menu')), findsNothing);
    });

    testWidgets('onMenu false keeps the viewer; true closes it', (
      tester,
    ) async {
      var answer = false;
      final asked = <String>[];
      await standalone(tester, (_, _, path) async {
        asked.add(path);
        return answer;
      });

      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();
      expect(asked, ['c1/1.png']);
      expect(find.byType(PhotoViewer), findsOneWidget);

      answer = true;
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();
      expect(asked, ['c1/1.png', 'c1/1.png']);
      expect(find.byType(PhotoViewer), findsNothing);
    });
  });

  // 0.30.13: the bubble that opened the viewer can be unmounted while the
  // viewer is open (new messages scroll it out of the lazy list). The
  // viewer menu must still reply, forward and delete -- it may not lean on
  // the bubble's ref, which is dead by then.
  group('the viewer menu after the bubble that opened it is gone', () {
    Future<ChatFake> openThenUnmount(WidgetTester tester) async {
      final c = await pump(tester, [
        msg('p1', body: '', attachment: 'c1/1.png'),
      ]);
      final chat = c.read(chatRepositoryProvider) as ChatFake;
      await tester.tap(find.byKey(const ValueKey('attachment-c1/1.png')));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      for (var i = 0; i < 40; i++) {
        chat.deliver(
          Message(
            id: 'n$i',
            conversationId: 'c1',
            senderId: bob,
            body: 'new $i\nline\nline',
            createdAt: DateTime.now(),
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('attachment-c1/1.png'), skipOffstage: false),
        findsNothing,
        reason: 'precondition: the opening bubble is unmounted',
      );
      expect(find.byType(PhotoViewer), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Your own photo: still never read-by in the viewer.
      expect(menuTiles(tester), ['reply', 'forward', 'delete']);
      return chat;
    }

    testWidgets('reply closes the viewer and starts the reply', (tester) async {
      await openThenUnmount(tester);
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(PhotoViewer), findsNothing);
      final c = ProviderScope.containerOf(
        tester.element(find.byType(MessageScreen)),
      );
      expect(c.read(replyingToProvider)?.id, 'p1');
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
    });

    testWidgets('forward sends it to the chat picked', (tester) async {
      final chat = await openThenUnmount(tester);
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(chat.forwarded, hasLength(1));
      expect(chat.forwarded.single.messageId, 'p1');
      expect(chat.forwarded.single.conversationIds, ['c2']);
      await tester.pump(const Duration(seconds: 10)); // the snackbar's timer
      await tester.pumpAndSettle();
    });

    testWidgets('delete for everyone deletes it', (tester) async {
      final chat = await openThenUnmount(tester);
      await tester.tap(find.byKey(const ValueKey('menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(chat.deleted, ['p1']);
    });
  });

  group('the floating card (0.30.9)', () {
    const safeTop = 40.0;
    const safeBottom = 30.0;
    const screen = Size(400, 800);

    /// A phone with a notch and a home bar.
    void phone(WidgetTester tester) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = screen
        ..padding = const FakeViewPadding(top: safeTop, bottom: safeBottom)
        ..viewPadding = const FakeViewPadding(top: safeTop, bottom: safeBottom);
      addTearDown(tester.view.reset);
    }

    void expectOnScreen(Rect r) {
      expect(r.left, greaterThanOrEqualTo(0), reason: 'left $r');
      expect(r.right, lessThanOrEqualTo(screen.width), reason: 'right $r');
      expect(r.top, greaterThanOrEqualTo(safeTop), reason: 'top $r');
      expect(
        r.bottom,
        lessThanOrEqualTo(screen.height - safeBottom),
        reason: 'bottom $r',
      );
    }

    testWidgets('is on screen one frame plus 120 ms after the tap', (
      tester,
    ) async {
      await pump(tester, [msg('m1', from: bob)]);
      await tester.tap(message('m1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(menu, findsOneWidget);
      for (final fade in tester.widgetList<FadeTransition>(
        find.ancestor(of: menu, matching: find.byType(FadeTransition)),
      )) {
        expect(fade.opacity.value, 1.0);
      }
      expect(find.byKey(const ValueKey('menu-reply')).hitTestable(), findsOne);
    });

    testWidgets('is no bottom sheet', (tester) async {
      await pump(tester, [msg('m1', from: bob)]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.ancestor(of: menu, matching: find.byType(ListTile)),
        findsNothing,
      );
    });

    testWidgets('a bubble low on the screen: the card sits above it', (
      tester,
    ) async {
      phone(tester);
      await pump(tester, [msg('m1', from: bob)]);
      final bubble = tester.getRect(message('m1'));
      expect(bubble.top, greaterThan(screen.height / 2), reason: 'low');
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();

      final card = tester.getRect(menu);
      expect(card.bottom, lessThanOrEqualTo(bubble.top));
      expect(bubble.top - card.bottom, lessThanOrEqualTo(24), reason: 'hugs');
      expectOnScreen(card);
    });

    testWidgets('the card hugs the bubble after the keyboard goes down', (
      tester,
    ) async {
      // A real keyboard: up while typing, and it slides away a few frames
      // AFTER the tap that unfocuses the composer, moving the bubble.
      phone(tester);
      await pump(tester, [msg('m1', from: bob, body: 'lunch?')]);
      await raiseKeyboard(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      await tester.tap(message('m1'));
      await tester.pump();
      expect(keyboardUp(tester), isFalse, reason: 'precondition: unfocused');
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();

      final bubble = tester.getRect(message('m1'));
      final card = tester.getRect(menu);
      expectOnScreen(card);
      expect(card.bottom, lessThanOrEqualTo(bubble.top));
      expect(
        bubble.top - card.bottom,
        lessThanOrEqualTo(24),
        reason: 'the card floats right above the bubble, not where it was',
      );
    });

    testWidgets('a bubble near the top: the card flips below it', (
      tester,
    ) async {
      phone(tester);
      await pump(tester, [
        for (var i = 0; i < 40; i++)
          msg('m$i', from: bob, body: 'line $i', minute: i),
      ]);
      final list = tester.getRect(
        find
            .ancestor(of: message('m39'), matching: find.byType(Scrollable))
            .first,
      );
      // The topmost bubble that is wholly inside the list.
      final top =
          [
              for (var i = 0; i < 40; i++)
                if (message('m$i').evaluate().isNotEmpty)
                  (i, tester.getRect(message('m$i'))),
            ].where((e) => e.$2.top >= list.top).toList()
            ..sort((a, b) => a.$2.top.compareTo(b.$2.top));
      final (id, bubble) = top.first;
      expect(bubble.top, lessThan(200), reason: 'near the top');

      await tester.tap(message('m$id'));
      await tester.pumpAndSettle();
      final card = tester.getRect(menu);
      expect(card.top, greaterThanOrEqualTo(bubble.bottom));
      expect(card.top - bubble.bottom, lessThanOrEqualTo(24), reason: 'hugs');
      expectOnScreen(card);
    });

    testWidgets('a tap outside: closed, nothing done', (tester) async {
      phone(tester);
      await pump(tester, [msg('m1', body: 'lunch?')]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      final card = tester.getRect(menu);
      final spot = Offset(screen.width - 10, card.top - 10);
      expect(card.contains(spot), isFalse);
      expect(tester.getRect(message('m1')).contains(spot), isFalse);

      await tester.tapAt(spot);
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
      expect(find.byKey(const ValueKey('edit-bar')), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
    });

    testWidgets('Back: only the card closes, nothing done', (tester) async {
      await pump(tester, [msg('m1', body: 'lunch?')]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
      expect(find.byKey(const ValueKey('edit-bar')), findsNothing);
    });

    testWidgets('a photo bubble opens it off the photo', (tester) async {
      await pump(tester, [
        msg('p1', from: bob, body: 'caption', attachment: 'c1/1.png'),
      ]);
      await tester.tap(find.byKey(const ValueKey('body-p1')));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      expect(find.byType(PhotoViewer), findsNothing);
    });

    testWidgets('copy writes the clipboard and says Copied', (tester) async {
      final copied = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester, [msg('m1', from: bob, body: 'lunch at noon')]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-copy')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(copied, ['lunch at noon']);
      expect(find.text('Copied'), findsOneWidget);
      expect(menu, findsNothing);
      // Let the notice time out.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('forward opens the forward picker', (tester) async {
      await pump(tester, [msg('m1', from: bob)]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byKey(const ValueKey('forward-c2')), findsOneWidget);
    });

    testWidgets('edit opens the edit bar with the text', (tester) async {
      await pump(tester, [msg('m1', body: 'typo hre')]);
      await tester.tap(message('m1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-edit')));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byKey(const ValueKey('edit-bar')), findsOneWidget);
      expect(tester.widget<TextField>(composer).controller!.text, 'typo hre');
    });

    testWidgets('the viewer card hangs from the top-right, unhighlighted', (
      tester,
    ) async {
      phone(tester);
      await pump(tester, [msg('p1', body: 'caption', attachment: 'c1/1.png')]);
      await tester.tap(find.byKey(const ValueKey('attachment-c1/1.png')));
      await tester.pumpAndSettle();
      final button = tester.getRect(find.byKey(const ValueKey('viewer-menu')));
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();

      final card = tester.getRect(menu);
      expectOnScreen(card);
      expect(card.right, greaterThan(screen.width - 32), reason: 'right');
      expect(card.top, greaterThanOrEqualTo(button.top), reason: 'under');
      expect(card.top - button.bottom, lessThanOrEqualTo(24), reason: 'hangs');
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  testWidgets('an emoji-only message renders big, text does not', (
    tester,
  ) async {
    await pump(tester, [
      msg('e', body: '\u{1F600}', minute: 1),
      msg('t', body: 'hi', minute: 2),
      msg('m', body: 'hi \u{1F600}', minute: 3),
    ]);
    double height(String s) =>
        tester.getSize(find.text(s, findRichText: true)).height;

    final text = height('hi');
    expect(height('\u{1F600}'), greaterThan(text * 1.5));
    expect(height('hi \u{1F600}'), text, reason: 'mixed stays text size');
  });
}
