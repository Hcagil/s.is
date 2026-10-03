// The 0.30.8 message menu and keyboard rules, driven through the real
// message screen. Written from the contract only:
//  * a tap on a message opens the `message-menu` sheet (tiles `menu-<action>`),
//    closes the keyboard and any open swipe row;
//  * a tap on empty space only closes the keyboard; scrolling does not;
//    send and the paperclip keep it open;
//  * long-press opens nothing;
//  * a photo, a link or a quote keeps its own tap;
//  * the photo viewer's `viewer-menu` offers Reply, Forward and Delete only,
//    exists only when the viewer was given onMenu, and closes the viewer when
//    onMenu says so.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

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
  final chat = ChatFake(
    self: me.userId,
    latency: const Duration(milliseconds: 5),
  )..history['c1'] = [...messages];
  for (final m in messages) {
    if (m.attachmentPath case final path?) chat.store(path);
  }
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(opener ?? LinkOpenerFake()),
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
      expect(menuTiles(tester), ['reply', 'copy', 'forward', 'edit', 'delete']);
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

    testWidgets('closes a swipe row that is open', (tester) async {
      await pump(tester, [
        msg('m1', from: bob),
        msg('m2', from: bob, minute: 1),
      ]);
      await tester.drag(message('m1'), swipeOpen);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('action-reply')), findsOneWidget);

      await tester.tap(message('m2'));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      // Dismiss the sheet the way a member does: the scrim.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(menu, findsNothing);
      expect(find.byKey(const ValueKey('action-reply')), findsNothing);
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

      expect(find.byKey(const ValueKey('attach-menu')), findsOneWidget);
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
      await standalone(tester, (_, path) async {
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
}
