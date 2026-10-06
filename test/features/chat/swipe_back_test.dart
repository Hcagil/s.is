// Leaving a page (0.30.13), on Android and iOS alike, from the owner's
// contract: one RIGHT drag that starts anywhere on a pushed page leaves it.
// The drag is claimed only when it goes right, past the touch slop, and is
// horizontal-dominant (|dx| > 2|dy|); its start closes the keyboard; the page
// follows the finger in the same frame; on release it pops at a velocity of
// >= 1.0 screen widths/s, or past 0.35 of the width unless flung back left
// faster than 1.0 widths/s; otherwise it springs back and stays. Only the
// current route, and only when pop gestures are enabled. The crop screen and
// the attachment preview opt out (their own drags stay theirs) but still
// leave on OS back.
//
// OS back is driven the way the engine drives it: the `popRoute` message
// and the predictive-back start/update/commit messages -- never
// Navigator.pop, which skips everything between the OS and the route. With
// the keyboard up, the first back is the IME's (it hides the keyboard); the
// keyboard inset dropping to 0 releases the composer's focus, so the second
// back leaves.
//
// Why 0.30.11's tests missed the device bug: they swiped from x = 5 px,
// which an Android phone under gesture navigation never delivers to the app
// (the system owns both edges), and they never sent OS back through the
// platform channel. Every drag here starts mid-screen with timed moves, on
// a phone-sized view, through the app's real theme and open* functions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/add_members_page.dart';
import 'package:sis/features/chat/presentation/attachment_preview_page.dart';
import 'package:sis/features/chat/presentation/forward_page.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/new_chat_page.dart';
import 'package:sis/features/chat/presentation/new_group_page.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';

/// A point mid-screen, clear of both system-gesture edges.
Offset mid(WidgetTester t) =>
    Offset(screenWidth(t) * 0.45, screenHeight(t) * 0.4);

void expectLeft(WidgetTester t) {
  expect(find.byType(MessageScreen), findsNothing, reason: 'still in chat');
  expect(launcher, findsOneWidget);
}

void expectStayed(WidgetTester t) {
  expect(find.byType(MessageScreen), findsOneWidget, reason: 'left the chat');
  expect(pageLeft(t), 0, reason: 'did not spring back to its place');
}

void main() {
  group('a right drag from anywhere leaves the chat', () {
    testWidgets('starting mid-screen on empty space', (t) async {
      final c = await openChat(t);
      await stroke(t, mid(t), Offset(screenWidth(t) * 0.6, 0));
      await settle(t);
      expectLeft(t);
      expect(c.read(openConversationProvider), isNull, reason: 'not closed');
    }, variant: platforms);

    testWidgets('starting on a bubble, in its middle', (t) async {
      final c = await openChat(t);
      await stroke(
        t,
        t.getCenter(bubble('m1')),
        Offset(screenWidth(t) * 0.6, 0),
      );
      await settle(t);
      expectLeft(t);
      expect(c.read(replyingToProvider), isNull, reason: 'started a reply');
    }, variant: platforms);

    testWidgets('starting at the very edge too (button navigation)', (t) async {
      await openChat(t);
      await stroke(
        t,
        Offset(5, screenHeight(t) / 2),
        Offset(screenWidth(t) * 0.6, 0),
      );
      await settle(t);
      expectLeft(t);
    }, variant: platforms);
  });

  group('while dragging', () {
    testWidgets('the page follows the finger in the same frame', (t) async {
      await openChat(t);
      final g = await t.startGesture(mid(t));
      await g.moveBy(const Offset(30, 0), timeStamp: ms(16));
      await t.pump();
      final first = pageLeft(t);
      expect(first, greaterThan(0), reason: 'did not move in the first frame');
      await g.moveBy(const Offset(50, 0), timeStamp: ms(32));
      await t.pump();
      expect(
        pageLeft(t) - first,
        moreOrLessEquals(50, epsilon: 0.5),
        reason: 'the page moves px for px with the finger',
      );
      await g.moveBy(const Offset(40, 0), timeStamp: ms(48));
      await t.pump();
      expect(pageLeft(t) - first, moreOrLessEquals(90, epsilon: 0.5));
      // Hold still, then let go short of 0.35: back to its place.
      await g.moveBy(Offset.zero, timeStamp: ms(780));
      await g.up(timeStamp: ms(800));
      await settle(t);
      expectStayed(t);
    }, variant: platforms);

    testWidgets('its start closes the keyboard', (t) async {
      await openChat(t);
      await t.tap(composer);
      await t.pump();
      expect(composerFocused(t), isTrue, reason: 'precondition: typing');

      final g = await stroke(
        t,
        mid(t),
        const Offset(60, 0),
        over: ms(600),
        steps: 6,
        release: false,
      );
      expect(composerFocused(t), isFalse, reason: 'keyboard still up mid-drag');
      await g.up(timeStamp: ms(600));
      await settle(t);
      expectStayed(t);
      expect(composerFocused(t), isFalse);
    }, variant: platforms);
  });

  group('on release', () {
    testWidgets('slow and short of 0.35 of the width: springs back, stays', (
      t,
    ) async {
      await openChat(t);
      // 0.30 of the width at 0.3 widths/s, 100 ms between moves.
      await stroke(
        t,
        mid(t),
        Offset(screenWidth(t) * 0.30, 0),
        over: ms(1000),
        steps: 10,
      );
      await settle(t);
      expectStayed(t);
    }, variant: platforms);

    testWidgets('slow but past 0.35 of the width: pops', (t) async {
      await openChat(t);
      await stroke(
        t,
        mid(t),
        Offset(screenWidth(t) * 0.45, 0),
        over: ms(1500),
        steps: 15,
      );
      await settle(t);
      expectLeft(t);
    }, variant: platforms);

    testWidgets('a short fast flick (>= 1 width/s) pops', (t) async {
      await openChat(t);
      // 0.2 of the width in 80 ms: 2.5 widths/s.
      await stroke(
        t,
        mid(t),
        Offset(screenWidth(t) * 0.2, 0),
        over: ms(80),
        steps: 8,
      );
      await settle(t);
      expectLeft(t);
    }, variant: platforms);

    testWidgets('past 0.35 but flung back left (< -1 width/s): stays', (
      t,
    ) async {
      await openChat(t);
      final w = screenWidth(t);
      final g = await stroke(
        t,
        mid(t),
        Offset(w * 0.55, 0),
        over: ms(1100),
        steps: 11,
        release: false,
      );
      // Back by 0.1 of the width in 40 ms: -2.5 widths/s, still at 0.45.
      await moveFinger(
        t,
        g,
        Offset(-w * 0.1, 0),
        over: ms(40),
        steps: 4,
        startAt: ms(1100),
      );
      await g.up(timeStamp: ms(1140));
      await settle(t);
      expectStayed(t);
    }, variant: platforms);
  });

  group('drags that are not claimed', () {
    testWidgets('a left drag on empty space', (t) async {
      await openChat(t);
      final g = await stroke(
        t,
        Offset(screenWidth(t) * 0.8, screenHeight(t) * 0.4),
        Offset(-screenWidth(t) * 0.6, 0),
        release: false,
      );
      expect(pageLeft(t), 0);
      await g.up(timeStamp: ms(300));
      await settle(t);
      expectStayed(t);
    }, variant: platforms);

    testWidgets('a steep diagonal (|dx| <= 2|dy|) scrolls, never leaves', (
      t,
    ) async {
      await openChat(t, messages: manyMessages(40));
      final w = screenWidth(t);
      // Right 0.5 of the width, down 0.3: dx is ahead of dy, so the touch
      // slop is crossed sideways first -- only the dominance rule stops it.
      final g = await stroke(
        t,
        mid(t),
        Offset(w * 0.5, w * 0.3),
        over: ms(1000),
        steps: 20,
        release: false,
      );
      expect(pageLeft(t), 0, reason: 'the page moved on a diagonal');
      await g.up(timeStamp: ms(1000));
      await settle(t);
      expectStayed(t);
    }, variant: platforms);

    testWidgets('a shallow diagonal (|dx| > 2|dy|) still leaves', (t) async {
      await openChat(t, messages: manyMessages(40));
      final w = screenWidth(t);
      await stroke(t, mid(t), Offset(w * 0.6, w * 0.2), steps: 20);
      await settle(t);
      expectLeft(t);
    }, variant: platforms);

    testWidgets('a vertical scroll neither leaves nor replies', (t) async {
      final c = await openChat(t, messages: manyMessages(40));
      final probe = bubble('m33');
      final from = Offset(screenWidth(t) * 0.5, screenHeight(t) * 0.45);
      final y0 = t.getTopLeft(probe).dy;
      // Down with a little right in it, then up with a little left.
      await stroke(t, from, const Offset(12, 220), over: ms(1200), steps: 24);
      await settle(t);
      final y1 = t.getTopLeft(probe).dy;
      expect(y1, greaterThan(y0 + 100), reason: 'the list did not scroll');
      expectStayed(t);
      await stroke(t, from, const Offset(-12, -100), over: ms(1000), steps: 20);
      await settle(t);
      expect(t.getTopLeft(probe).dy, lessThan(y1 - 50), reason: 'no scroll');
      expectStayed(t);
      expect(c.read(replyingToProvider), isNull, reason: 'a scroll replied');
    }, variant: platforms);
  });

  group('which route', () {
    testWidgets('only the top page leaves, one drag at a time', (t) async {
      await openChat(t);
      showNewChatPage(t.element(find.byType(MessageScreen)));
      await settle(t);
      expect(find.byType(NewChatPage), findsOneWidget);

      await stroke(t, mid(t), Offset(screenWidth(t) * 0.6, 0));
      await settle(t);
      expect(find.byType(NewChatPage), findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget, reason: 'two popped');

      await stroke(t, mid(t), Offset(screenWidth(t) * 0.6, 0));
      await settle(t);
      expectLeft(t);
    }, variant: platforms);

    testWidgets('with the photo viewer over it (a see-through route), the '
        'chat is not the current page: a right drag does not leave it', (
      t,
    ) async {
      final repo = ChatFake(self: me.userId)
        ..history['c1'] = [
          Message(
            id: 'p1',
            conversationId: 'c1',
            senderId: bob.userId,
            body: '',
            createdAt: DateTime.now(),
            attachmentPath: 'c1/1.png',
          ),
        ]
        ..roster['c1'] = [me, bob]
        ..membersResult = const Ok([bob]);
      repo.store('c1/1.png');
      await pumpLauncher(
        t,
        (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
        chat: repo,
      );
      // The photo decodes in the engine, outside the fake clock.
      for (
        var i = 0;
        i < 20 && find.byType(PhotoViewer).evaluate().isEmpty;
        i++
      ) {
        await settle(t);
        await t.tap(find.byKey(const ValueKey('attachment-c1/1.png')));
        await settle(t);
      }
      expect(find.byType(PhotoViewer), findsOneWidget);

      await stroke(
        t,
        mid(t),
        Offset(screenWidth(t) * 0.6, 0),
        over: ms(1200),
        steps: 20,
      );
      await settle(t);
      expect(
        find.byType(MessageScreen),
        findsOneWidget,
        reason: 'the chat under the viewer left',
      );
    }, variant: platforms);

    testWidgets('with the message card open, a right drag does not leave '
        'the chat', (t) async {
      await openChat(t);
      await t.longPress(bubble('m1'));
      await settle(t);
      expect(find.byKey(const ValueKey('message-menu')), findsOneWidget);
      await stroke(
        t,
        Offset(screenWidth(t) * 0.3, screenHeight(t) * 0.15),
        Offset(screenWidth(t) * 0.6, 0),
      );
      await settle(t);
      expect(find.byType(MessageScreen), findsOneWidget);
    }, variant: platforms);

    testWidgets('a page that refuses to pop (PopScope) stays', (t) async {
      await pumpLauncher(
        t,
        (context, _) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const PopScope(
              canPop: false,
              child: Scaffold(body: SizedBox.expand(key: ValueKey('locked'))),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('locked')), findsOneWidget);
      await stroke(t, mid(t), Offset(screenWidth(t) * 0.6, 0));
      await settle(t);
      expect(find.byKey(const ValueKey('locked')), findsOneWidget);
    }, variant: platforms);

    testWidgets('a page still sliding in does not start a drag', (t) async {
      await pumpLauncher(
        t,
        (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
        tap: false,
      );
      await t.tap(launcher);
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      expect(find.byType(MessageScreen), findsOneWidget);
      await stroke(
        t,
        mid(t),
        Offset(screenWidth(t) * 0.3, 0),
        over: ms(60),
        steps: 6,
      );
      await settle(t);
      expectStayed(t);
    }, variant: platforms);
  });

  group('every covered page leaves on a mid-screen right drag', () {
    final pages = <String, (Type, Launch)>{
      'forward': (
        ForwardPage,
        (context, ref) => showForwardPage(context, ref, chatMessage('m1')),
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
    };

    for (final MapEntry(key: name, value: (type, launch)) in pages.entries) {
      testWidgets(name, (t) async {
        await pumpLauncher(t, launch);
        expect(find.byType(type), findsOneWidget, reason: 'never opened');
        await stroke(t, mid(t), Offset(screenWidth(t) * 0.6, 0));
        await settle(t);
        expect(find.byType(type), findsNothing, reason: 'still open');
        expect(launcher, findsOneWidget);
      }, variant: platforms);
    }
  });

  group('opt-out: the attachment preview', () {
    Future<void> open(WidgetTester t) async {
      await pumpLauncher(
        t,
        (context, _) => showAttachmentPreview(context, images: [pickedPng()]),
      );
      expect(find.byType(AttachmentPreviewPage), findsOneWidget);
    }

    testWidgets('a mid-screen right drag does not leave it', (t) async {
      await open(t);
      await stroke(t, mid(t), Offset(screenWidth(t) * 0.6, 0));
      await settle(t);
      expect(find.byType(AttachmentPreviewPage), findsOneWidget);
    }, variant: platforms);

    testWidgets('OS back still leaves it', (t) async {
      await open(t);
      await osBack(t);
      expect(find.byType(AttachmentPreviewPage), findsNothing);
      expect(launcher, findsOneWidget);
    }, variant: platforms);
  });

  group('OS back, through the platform channel', () {
    testWidgets('popRoute leaves the chat', (t) async {
      final c = await openChat(t);
      await osBack(t);
      expectLeft(t);
      expect(c.read(openConversationProvider), isNull);
    }, variant: platforms);

    testWidgets('predictive back: start, update, commit leaves the chat', (
      t,
    ) async {
      await openChat(t);
      await backGesture(t, 'startBackGesture');
      await backGesture(t, 'updateBackGestureProgress', 0.3);
      await backGesture(t, 'updateBackGestureProgress', 0.7);
      await backGesture(t, 'commitBackGesture');
      await settle(t);
      expectLeft(t);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('predictive back cancelled stays in the chat', (t) async {
      await openChat(t);
      await backGesture(t, 'startBackGesture');
      await backGesture(t, 'updateBackGestureProgress', 0.4);
      await backGesture(t, 'cancelBackGesture');
      await settle(t);
      expectStayed(t);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('keyboard up: the IME takes the first back (the inset drops '
        'to 0), focus goes with it, and the second back leaves', (t) async {
      await openChat(t);
      await t.tap(composer);
      await keyboardInset(t, 300);
      expect(composerFocused(t), isTrue, reason: 'precondition: typing');

      // First back: Android's IME consumes it and hides the keyboard; the
      // app only sees the inset go to 0.
      await keyboardInset(t, 0);
      expect(composerFocused(t), isFalse, reason: 'focus kept: back is lost');
      expect(find.byType(MessageScreen), findsOneWidget);

      await osBack(t);
      expectLeft(t);
    }, variant: platforms);

    testWidgets('keyboard up: predictive back after the IME closed it leaves', (
      t,
    ) async {
      await openChat(t);
      await t.tap(composer);
      await keyboardInset(t, 300);
      await keyboardInset(t, 0);

      await backGesture(t, 'startBackGesture');
      await backGesture(t, 'updateBackGestureProgress', 0.6);
      await backGesture(t, 'commitBackGesture');
      await settle(t);
      expectLeft(t);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}

typedef Launch = void Function(BuildContext, WidgetRef);

Duration ms(int n) => Duration(milliseconds: n);
