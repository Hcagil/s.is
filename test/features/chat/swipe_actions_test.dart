// What a finger does to one message (0.30.13), from the owner's contract,
// through the chat as production opens it (sisTheme, openConversation, a
// phone-sized view), on Android and iOS:
//  * swipe LEFT = reply, offered only when the message's actions include
//    reply: the bubble follows the finger up to 96 px with a reply arrow;
//    one heavy-impact haptic when the pull first reaches 64 px; released at
//    >= 64 px the reply target is set and the composer focused; under 64 px
//    nothing; either way it springs back in 180 ms;
//  * a RIGHT drag on a message is not the message's: it leaves the chat;
//  * a tap opens the message (seen-by pill, reactions bar) and no card; a
//    long-press opens the floating action card (Update 1 slice 7);
//  * a screen reader still gets every action as a custom action;
//  * vertical scroll never replies; reply and leave never trigger each other.
// Written from the contract, never from how the widgets are built.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/swipeable_message.dart';

import '../../support/chat_launcher.dart';
import '../../support/sis_ui.dart';

/// The contract's numbers, in bubble travel (logical px).
const threshold = 64.0;
const clamp = 96.0;
const click = 'HapticFeedbackType.heavyImpact';

double left(WidgetTester t, Finder f) => t.getTopLeft(f).dx;

/// How far [id]'s bubble has been pulled left of [start].
double pulled(WidgetTester t, String id, double start) =>
    start - left(t, bubble(id));

final menu = find.byKey(const ValueKey('message-menu'));
final replyArrow = find.byIcon(swipeActionIcon(MessageAction.reply));

/// Puts a finger on [id], drags left past the touch slop, then moves it so
/// the bubble has travelled exactly [travel] px, and holds it there.
Future<TestGesture> holdAt(WidgetTester t, String id, double travel) async {
  final start = left(t, bubble(id));
  final g = await t.startGesture(t.getCenter(bubble(id)));
  await g.moveBy(const Offset(-20, 0));
  await t.pump();
  final moved = pulled(t, id, start);
  await g.moveBy(Offset(-(travel - moved), 0));
  await t.pump();
  return g;
}

void main() {
  group('swipe left to reply', () {
    testWidgets('the bubble follows the finger in the same frame, px for '
        'px, and stops at 96 with a reply arrow', (t) async {
      await openChat(t);
      final start = left(t, bubble('m1'));
      expect(replyArrow, findsNothing, reason: 'arrow before any drag');

      final g = await holdAt(t, 'm1', 30);
      expect(pulled(t, 'm1', start), 30);
      expect(replyArrow, findsOneWidget, reason: 'no reply arrow mid-drag');
      await g.moveBy(const Offset(-12, 0));
      await t.pump();
      expect(pulled(t, 'm1', start), 42, reason: 'moves with the finger');
      await g.moveBy(const Offset(-200, 0));
      await t.pump();
      expect(pulled(t, 'm1', start), clamp);
      expect(pageLeft(t), 0, reason: 'a reply drag moved the page');
      await g.up();
      await settle(t);
    }, variant: platforms);

    testWidgets('released 1 px short of 64: nothing happens, no haptic', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final c = await openChat(t);
      final start = left(t, bubble('m1'));

      final g = await holdAt(t, 'm1', threshold - 1);
      await g.up();
      await settle(t);

      expect(left(t, bubble('m1')), start);
      expect(c.read(replyingToProvider), isNull);
      expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
      expect(composerFocused(t), isFalse);
      expect(haptics, isEmpty);
      expect(menu, findsNothing);
    }, variant: platforms);

    testWidgets('one haptic the moment the pull first reaches 64, none on '
        'the way on to 96', (t) async {
      final haptics = recordHaptics(t);
      await openChat(t);

      final g = await holdAt(t, 'm1', threshold - 1);
      expect(haptics, isEmpty, reason: 'ticked before 64');
      await g.moveBy(const Offset(-1, 0));
      await t.pump();
      expect(haptics, [click], reason: 'no tick at 64');
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(-10, 0));
        await t.pump();
      }
      expect(haptics, [click]);
      await g.up();
      await settle(t);
      expect(haptics, [click], reason: 'ticked on release');
    }, variant: platforms);

    testWidgets('pulled back under 64 and past it again in the same drag: '
        'still one haptic ("when the pull FIRST reaches 64")', (t) async {
      final haptics = recordHaptics(t);
      await openChat(t);

      final g = await holdAt(t, 'm1', 80);
      expect(haptics, [click]);
      await g.moveBy(const Offset(40, 0)); // back under 64
      await t.pump();
      await g.moveBy(const Offset(-40, 0)); // past it again
      await t.pump();
      expect(haptics, [click], reason: 'ticked again on re-crossing 64');
      await g.up();
      await settle(t);
    }, variant: platforms);

    testWidgets('released at 64: replies to that message and focuses the '
        'composer', (t) async {
      final c = await openChat(t);
      expect(composerFocused(t), isFalse);

      final g = await holdAt(t, 'm1', threshold);
      await g.up();
      await settle(t);

      expect(c.read(replyingToProvider)?.id, 'm1');
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
      expect(composerFocused(t), isTrue, reason: 'the keyboard did not open');
      expect(menu, findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
    }, variant: platforms);

    testWidgets('your own message replies the same way', (t) async {
      final c = await openChat(
        t,
        messages: [chatMessage('m1', from: me.userId)],
      );
      final g = await holdAt(t, 'm1', clamp);
      await g.up();
      await settle(t);
      expect(c.read(replyingToProvider)?.id, 'm1');
    }, variant: platforms);

    testWidgets('springs back over 180 ms, easing, not jumping', (t) async {
      await openChat(t);
      final start = left(t, bubble('m1'));

      final g = await holdAt(t, 'm1', clamp);
      await g.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 90));
      final mid = pulled(t, 'm1', start);
      expect(mid, greaterThan(0), reason: 'jumped home');
      expect(mid, lessThan(clamp), reason: 'did not start back');

      await t.pump(const Duration(milliseconds: 90));
      await t.pump();
      expect(left(t, bubble('m1')), start, reason: 'not home by 180 ms');
      await settle(t);
    }, variant: platforms);

    testWidgets('a deleted message does not move and replies to nothing', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final c = await openChat(
        t,
        messages: [
          chatMessage(
            'm1',
            from: me.userId,
            body: '',
            deletion: MessageDeletion.placeholder,
          ),
        ],
      );
      final deleted = find.byKey(const ValueKey('deleted-m1'));
      final start = left(t, deleted);
      final g = await t.startGesture(t.getCenter(deleted));
      await g.moveBy(const Offset(-20, 0));
      await g.moveBy(const Offset(-80, 0));
      await t.pump();
      expect(left(t, deleted), start, reason: 'moved mid-drag');
      await g.up();
      await settle(t);
      expect(c.read(replyingToProvider), isNull);
      expect(haptics, isEmpty);
    }, variant: platforms);

    testWidgets('a pending photo does not move and replies to nothing', (
      t,
    ) async {
      final c = await pumpLauncher(
        t,
        (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
        messages: [chatMessage('m1', from: me.userId, pending: true)],
        tap: false,
      );
      await t.tap(launcher);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final start = left(t, bubble('m1'));
      final g = await t.startGesture(t.getCenter(bubble('m1')));
      await g.moveBy(const Offset(-20, 0));
      await g.moveBy(const Offset(-80, 0));
      await t.pump();
      expect(left(t, bubble('m1')), start, reason: 'moved mid-drag');
      await g.up();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(c.read(replyingToProvider), isNull);
    }, variant: platforms);
  });

  group('a right drag on a message is not the message\'s', () {
    testWidgets('the bubble does not move right; the chat leaves; no reply', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final c = await openChat(t);
      final start = left(t, bubble('m1'));
      final page0 = pageLeft(t);

      final g = await stroke(
        t,
        t.getCenter(bubble('m1')),
        const Offset(120, 0),
        over: const Duration(milliseconds: 1200),
        steps: 12,
        release: false,
      );
      final pageMoved = pageLeft(t) - page0;
      expect(pageMoved, greaterThan(60), reason: 'the page did not follow');
      expect(
        left(t, bubble('m1')) - start,
        moreOrLessEquals(pageMoved, epsilon: 0.5),
        reason: 'the bubble moved on its own, not with the page',
      );
      await moveFinger(
        t,
        g,
        Offset(screenWidth(t) * 0.4, 0),
        over: const Duration(milliseconds: 400),
        steps: 8,
        startAt: const Duration(milliseconds: 1200),
      );
      await g.up(timeStamp: const Duration(milliseconds: 1600));
      await settle(t);

      expect(find.byType(MessageScreen), findsNothing);
      expect(c.read(replyingToProvider), isNull);
      expect(haptics, isEmpty);
    }, variant: platforms);
  });

  group('vertical scroll', () {
    testWidgets('with some left in it, it scrolls and never replies', (
      t,
    ) async {
      final haptics = recordHaptics(t);
      final c = await openChat(t, messages: manyMessages(40));
      final probe = bubble('m33');
      final x0 = left(t, probe);
      final y0 = t.getTopLeft(probe).dy;
      final g = await stroke(
        t,
        t.getCenter(bubble('m36')),
        const Offset(-30, 200),
        over: const Duration(milliseconds: 1200),
        steps: 24,
        release: false,
      );
      expect(t.getTopLeft(probe).dy, greaterThan(y0 + 100), reason: 'scroll');
      expect(left(t, probe), x0, reason: 'a bubble moved sideways');
      await g.up(timeStamp: const Duration(milliseconds: 1200));
      await settle(t);
      expect(c.read(replyingToProvider), isNull);
      expect(haptics, isEmpty);
      expect(find.byType(MessageScreen), findsOneWidget);
    }, variant: platforms);
  });

  group('tap and long-press', () {
    testWidgets('a tap opens the message, no card, and moves nothing', (
      t,
    ) async {
      final c = await openChat(t);
      final start = left(t, bubble('m1'));
      await t.tap(bubble('m1'));
      await settle(t);
      expect(c.read(tappedMessageProvider), 'm1');
      expect(menu, findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(left(t, bubble('m1')), start);
      expect(c.read(replyingToProvider), isNull);
    }, variant: platforms);

    testWidgets('long-press opens the floating message card and moves '
        'nothing', (t) async {
      final c = await openChat(t);
      final start = left(t, bubble('m1'));
      await t.longPress(bubble('m1'));
      await settle(t);
      expect(menu, findsOneWidget);
      expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-forward')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(left(t, bubble('m1')), start);
      expect(c.read(replyingToProvider), isNull);
    }, variant: platforms);
  });

  group('a screen reader gets every action', () {
    const labels = {
      'reply': 'Reply',
      'forward': 'Forward',
      'edit': 'Edit',
      'delete': 'Delete for everyone',
    };

    testWidgets('per message kind, one custom action per allowed action', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      final old = DateTime.now().subtract(const Duration(hours: 7));
      await openChat(
        t,
        messages: [
          chatMessage('own', body: 'mine fresh', from: me.userId),
          chatMessage('old', body: 'mine old', from: me.userId, createdAt: old),
          chatMessage('bob', body: 'from bob'),
          chatMessage('del', body: '', deletion: MessageDeletion.placeholder),
        ],
      );
      expect(
        actionLabels(actionsNode(t, bubble('own'))),
        unorderedEquals(labels.values),
      );
      expect(
        actionLabels(actionsNode(t, bubble('old'))),
        unorderedEquals(['Reply', 'Forward', 'Delete for everyone']),
      );
      expect(
        actionLabels(actionsNode(t, bubble('bob'))),
        unorderedEquals(['Reply', 'Forward']),
      );
      expect(actionsNode(t, find.byKey(const ValueKey('deleted-del'))), isNull);
      handle.dispose();
    });

    testWidgets('Reply runs the reply', (t) async {
      final handle = t.ensureSemantics();
      final c = await openChat(t);
      invokeAction(actionsNode(t, bubble('m1'))!, 'Reply');
      await settle(t);
      expect(c.read(replyingToProvider)?.id, 'm1');
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Forward runs the forward', (t) async {
      final handle = t.ensureSemantics();
      await openChat(t);
      invokeAction(actionsNode(t, bubble('m1'))!, 'Forward');
      await settle(t);
      expect(find.byKey(const ValueKey('forward-c2')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Edit runs the edit', (t) async {
      final handle = t.ensureSemantics();
      await openChat(t, messages: [chatMessage('m1', from: me.userId)]);
      invokeAction(actionsNode(t, bubble('m1'))!, 'Edit');
      await settle(t);
      expect(find.byKey(const ValueKey('edit-bar')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Delete for everyone asks first', (t) async {
      final handle = t.ensureSemantics();
      await openChat(t, messages: [chatMessage('m1', from: me.userId)]);
      invokeAction(actionsNode(t, bubble('m1'))!, 'Delete for everyone');
      await settle(t);
      expect(find.byKey(const ValueKey('delete-confirm')), findsOneWidget);
      handle.dispose();
    });
  });
}
