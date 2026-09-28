// Swiping a message to act on it, through the real MessageScreen, from the
// decision "Swipe a message to act on it" (docs/DECISIONS.md): the bubble
// follows the finger to the right; released past a threshold, a row of the
// allowed actions opens above it with one haptic tick, and on every release
// the bubble springs back to its place; dragging never closes the row, which
// closes on an action, a tap elsewhere, a scroll or another row opening; one
// row is open at a time; long press does nothing; deleted and pending bubbles
// do not swipe; a screen reader gets the same actions. Written from the
// contract, never from how the widgets are built.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/swipeable_message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

/// The contract's numbers, in bubble travel (logical px).
const threshold = 64.0;
const clamp = 88.0;

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  DateTime? createdAt,
  String? photo,
  bool pending = false,
  bool forwarded = false,
  MessageDeletion? deletion,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: createdAt ?? DateTime.now(),
  attachmentPath: photo,
  localImage: pending ? pngBytes : null,
  forwarded: forwarded,
  deletion: deletion,
);

/// [n] text messages from bob and me alternately, oldest first, newest 'm{n-1}'.
List<Message> many(int n) => [
  for (var i = 0; i < n; i++)
    msg(
      'm$i',
      body: 'message number $i',
      from: i.isEven ? bob.userId : me.userId,
      createdAt: DateTime.now().subtract(Duration(minutes: n - i)),
    ),
];

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

ChatFake chatWith(List<Message> messages) => ChatFake(self: me.userId)
  ..history['c1'] = messages
  ..membersResult = const Ok([bob, cem])
  ..conversationsResult = const Ok([
    Conversation(id: 'c1', title: 'Bob'),
    Conversation(id: 'c2', title: 'Work'),
  ]);

Future<void> pump(
  WidgetTester tester,
  ChatFake chat, {
  bool group = false,
  bool settle = true,
}) async {
  chat.roster['c1'] = [me, bob, cem];
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  addTearDown(container.dispose);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: MessageScreen(title: 'Bob', group: group),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await frames(tester);
  }
}

/// Bounded frames, for a pending photo whose spinner never settles.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder bubble(String id) => find.byKey(ValueKey('message-$id'));
Finder row(String id) => find.byKey(ValueKey('swipe-actions-$id'));
Finder box(String name) => find.byKey(ValueKey('action-$name'));
const boxes = ['read-by', 'reply', 'forward', 'edit', 'delete'];

/// The action boxes on screen, by name.
List<String> shownBoxes() => [
  for (final b in boxes)
    if (box(b).evaluate().isNotEmpty) b,
];

double left(WidgetTester t, Finder f) => t.getTopLeft(f).dx;

/// Every HapticFeedback call the app makes, by type.
List<String> recordHaptics(WidgetTester tester) {
  final calls = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      calls.add(call.arguments as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

/// Puts a finger on [id], drags right past the touch slop, then moves it so
/// the bubble has travelled exactly [travel] px, and holds it there.
Future<TestGesture> holdAt(
  WidgetTester tester,
  String id,
  double travel,
) async {
  final start = left(tester, bubble(id));
  final g = await tester.startGesture(tester.getCenter(bubble(id)));
  await g.moveBy(const Offset(20, 0));
  await tester.pump();
  final moved = left(tester, bubble(id)) - start;
  await g.moveBy(Offset(travel - moved, 0));
  await tester.pump();
  return g;
}

Future<void> open(WidgetTester tester, String id) async {
  await tester.drag(bubble(id), swipeOpen);
  await tester.pumpAndSettle();
  expect(row(id), findsOneWidget, reason: 'the row for $id did not open');
}

/// The semantics node carrying [id]'s custom actions, or null: the nearest
/// node at or above its bubble that has any.
SemanticsNode? actionsNode(WidgetTester tester, Finder f) {
  SemanticsNode? node = tester.getSemantics(f);
  while (node != null) {
    final ids = node.getSemanticsData().customSemanticsActionIds;
    if (ids != null && ids.isNotEmpty) return node;
    node = node.parent;
  }
  return null;
}

List<String> actionLabels(SemanticsNode? node) => [
  for (final id in node?.getSemanticsData().customSemanticsActionIds ?? [])
    CustomSemanticsAction.getAction(id)!.label ?? '',
];

void invoke(SemanticsNode node, String label) {
  final id = node.getSemanticsData().customSemanticsActionIds!.firstWhere(
    (id) => CustomSemanticsAction.getAction(id)!.label == label,
  );
  node.owner!.performAction(node.id, SemanticsAction.customAction, id);
}

void main() {
  group('the gesture', () {
    testWidgets('the bubble follows the finger and stops at 88', (
      tester,
    ) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));

      final g = await holdAt(tester, 'm1', 30);
      expect(left(tester, bubble('m1')) - start, 30);
      await g.moveBy(const Offset(12, 0));
      await tester.pump();
      expect(
        left(tester, bubble('m1')) - start,
        42,
        reason: 'the bubble moves with the finger, px for px',
      );
      await g.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(left(tester, bubble('m1')) - start, clamp);
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('released 1 px short of the threshold, it springs back and '
        'nothing opens', (tester) async {
      final haptics = recordHaptics(tester);
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));

      final g = await holdAt(tester, 'm1', threshold - 1);
      await g.up();
      await tester.pumpAndSettle();

      expect(left(tester, bubble('m1')), start);
      expect(row('m1'), findsNothing);
      expect(shownBoxes(), isEmpty);
      expect(haptics, isEmpty);
    });

    testWidgets('released at the threshold, the row opens with one selection '
        'tick and the bubble springs back to its place', (tester) async {
      final haptics = recordHaptics(tester);
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));

      final g = await holdAt(tester, 'm1', threshold);
      await g.up();
      await tester.pumpAndSettle();

      expect(left(tester, bubble('m1')), start, reason: 'springs back to 0');
      expect(row('m1'), findsOneWidget, reason: 'the row stays open');
      expect(haptics, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('dragged to the clamp and released, it springs back to its '
        'place, still one tick', (tester) async {
      final haptics = recordHaptics(tester);
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));

      final g = await holdAt(tester, 'm1', 30);
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      expect(left(tester, bubble('m1')) - start, clamp);
      await g.up();
      await tester.pumpAndSettle();

      expect(left(tester, bubble('m1')), start);
      expect(row('m1'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('on release the row is open at once while the bubble eases '
        'back over 180 ms', (tester) async {
      final haptics = recordHaptics(tester);
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));

      final g = await holdAt(tester, 'm1', clamp);
      await g.up();
      await tester.pump(); // the first frame after release starts the ease
      expect(row('m1'), findsOneWidget, reason: 'open at release');
      expect(haptics, ['HapticFeedbackType.selectionClick']);

      await tester.pump(const Duration(milliseconds: 90));
      final mid = left(tester, bubble('m1')) - start;
      expect(mid, greaterThan(0), reason: 'animates, does not jump');
      expect(
        mid,
        lessThan(clamp / 2),
        reason: 'easeOut: past half the way home at half the time',
      );
      expect(row('m1'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 90));
      await tester.pump();
      expect(left(tester, bubble('m1')), start, reason: 'home by 180 ms');
      expect(row('m1'), findsOneWidget);
    });

    testWidgets('the row is not built mid-drag, even past the threshold', (
      tester,
    ) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));

      final g = await holdAt(tester, 'm1', 80);
      expect(row('m1'), findsNothing);
      expect(shownBoxes(), isEmpty);
      await g.up();
      await tester.pumpAndSettle();
      expect(row('m1'), findsOneWidget);
    });

    testWidgets('the row sits above the bubble at its resting place', (
      tester,
    ) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));
      await open(tester, 'm1');
      expect(left(tester, bubble('m1')), start);
      expect(
        tester.getRect(row('m1')).bottom,
        lessThanOrEqualTo(tester.getRect(bubble('m1')).top),
      );
    });

    testWidgets('a drag left on an open bubble leaves it open', (tester) async {
      final haptics = recordHaptics(tester);
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      final start = left(tester, bubble('m1'));
      await open(tester, 'm1');

      await tester.drag(bubble('m1'), const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(row('m1'), findsOneWidget);
      expect(left(tester, bubble('m1')), start);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
    });

    for (final travel in [30.0, clamp]) {
      testWidgets('an open bubble dragged right again by $travel px stays '
          'open, springs back, and does not tick again', (tester) async {
        final haptics = recordHaptics(tester);
        await pump(tester, chatWith([msg('m1', from: bob.userId)]));
        final start = left(tester, bubble('m1'));
        await open(tester, 'm1');
        expect(haptics, hasLength(1));

        final g = await holdAt(tester, 'm1', travel);
        await g.up();
        await tester.pumpAndSettle();

        expect(row('m1'), findsOneWidget);
        expect(left(tester, bubble('m1')), start);
        expect(haptics, ['HapticFeedbackType.selectionClick']);
      });
    }

    testWidgets('a mostly vertical drag on a bubble scrolls the list and '
        'does not swipe', (tester) async {
      await pump(tester, chatWith(many(40)));
      final target = bubble('m37');
      final before = tester.getTopLeft(target);

      await tester.drag(target, const Offset(20, 150));
      await tester.pumpAndSettle();

      final after = tester.getTopLeft(target);
      expect(after.dy, greaterThan(before.dy), reason: 'the list scrolled');
      expect(after.dx, before.dx, reason: 'the bubble did not move sideways');
      expect(row('m37'), findsNothing);
      expect(shownBoxes(), isEmpty);
    });

    testWidgets('long press opens nothing', (tester) async {
      await pump(tester, chatWith([msg('m1')]));
      final start = left(tester, bubble('m1'));

      await tester.longPress(bubble('m1'));
      await tester.pumpAndSettle();

      expect(row('m1'), findsNothing);
      expect(shownBoxes(), isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(left(tester, bubble('m1')), start);
    });
  });

  group('what the row offers', () {
    testWidgets('your own fresh text in a 1:1: reply, forward, edit, delete', (
      tester,
    ) async {
      await pump(tester, chatWith([msg('m1')]));
      await open(tester, 'm1');
      expect(shownBoxes(), ['reply', 'forward', 'edit', 'delete']);
    });

    testWidgets('your own fresh text in a group adds read-by', (tester) async {
      await pump(tester, chatWith([msg('m1')]), group: true);
      await open(tester, 'm1');
      expect(shownBoxes(), ['read-by', 'reply', 'forward', 'edit', 'delete']);
    });

    testWidgets('your own text over 6 h in a group: read-by, reply, forward', (
      tester,
    ) async {
      final old = DateTime.now().subtract(const Duration(hours: 7));
      await pump(tester, chatWith([msg('m1', createdAt: old)]), group: true);
      await open(tester, 'm1');
      expect(shownBoxes(), ['read-by', 'reply', 'forward']);
    });

    testWidgets('your own forwarded message: no edit', (tester) async {
      await pump(tester, chatWith([msg('m1', forwarded: true)]));
      await open(tester, 'm1');
      expect(shownBoxes(), ['reply', 'forward', 'delete']);
    });

    testWidgets("somebody else's text: reply and forward only", (tester) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]), group: true);
      await open(tester, 'm1');
      expect(shownBoxes(), ['reply', 'forward']);
    });

    testWidgets('your own stored photo swipes like text', (tester) async {
      final chat = chatWith([msg('p1', body: 'caption', photo: 'c1/1.png')])
        ..store('c1/1.png');
      await pump(tester, chat);
      await open(tester, 'p1');
      expect(shownBoxes(), ['reply', 'forward', 'edit', 'delete']);
    });

    testWidgets("somebody else's photo: reply and forward", (tester) async {
      final chat = chatWith([
        msg('p1', from: bob.userId, body: '', photo: 'c1/1.png'),
      ])..store('c1/1.png');
      await pump(tester, chat);
      await open(tester, 'p1');
      expect(shownBoxes(), ['reply', 'forward']);
    });

    testWidgets('a deleted bubble does not move and offers nothing', (
      tester,
    ) async {
      await pump(
        tester,
        chatWith([msg('m1', body: '', deletion: MessageDeletion.placeholder)]),
      );
      final deleted = find.byKey(const ValueKey('deleted-m1'));
      final start = left(tester, deleted);

      final g = await tester.startGesture(tester.getCenter(deleted));
      await g.moveBy(const Offset(20, 0));
      await g.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(left(tester, deleted), start, reason: 'moved mid-drag');
      await g.up();
      await tester.pumpAndSettle();

      expect(row('m1'), findsNothing);
      expect(shownBoxes(), isEmpty);
    });

    testWidgets('a pending photo does not move and offers nothing', (
      tester,
    ) async {
      await pump(tester, chatWith([msg('m1', pending: true)]), settle: false);
      final start = left(tester, bubble('m1'));

      final g = await tester.startGesture(tester.getCenter(bubble('m1')));
      await g.moveBy(const Offset(20, 0));
      await g.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(left(tester, bubble('m1')), start, reason: 'moved mid-drag');
      await g.up();
      await frames(tester);

      expect(row('m1'), findsNothing);
      expect(shownBoxes(), isEmpty);
    });
  });

  group('closing', () {
    testWidgets('opening a second bubble closes the first', (tester) async {
      await pump(
        tester,
        chatWith([
          msg('m1', from: bob.userId, body: 'first'),
          msg('m2', from: bob.userId, body: 'second'),
        ]),
      );
      final start = left(tester, bubble('m1'));
      await open(tester, 'm1');

      await open(tester, 'm2');

      expect(row('m1'), findsNothing);
      expect(left(tester, bubble('m1')), start);
      expect(row('m2'), findsOneWidget);
      expect(box('reply'), findsOneWidget, reason: 'one row, not two');
    });

    testWidgets('a tap on another bubble closes the row', (tester) async {
      await pump(
        tester,
        chatWith([
          msg('m1', from: bob.userId, body: 'first'),
          msg('m2', from: bob.userId, body: 'second'),
        ]),
      );
      final start = left(tester, bubble('m2'));
      await open(tester, 'm2');

      await tester.tap(bubble('m1'));
      await tester.pumpAndSettle();

      expect(row('m2'), findsNothing);
      expect(left(tester, bubble('m2')), start);
    });

    testWidgets('a tap on empty space in the list closes the row', (
      tester,
    ) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      await open(tester, 'm1');
      final list = tester.getRect(
        find
            .ancestor(of: bubble('m1'), matching: find.byType(Scrollable))
            .first,
      );
      final rowRect = tester.getRect(row('m1'));
      final bubbleRect = tester.getRect(bubble('m1'));
      // A point inside the list, clear of the row and the bubble.
      final spot = Offset(list.right - 20, list.top + 20);
      expect(list.contains(spot), isTrue);
      expect(rowRect.contains(spot) || bubbleRect.contains(spot), isFalse);

      await tester.tapAt(spot);
      await tester.pumpAndSettle();

      expect(row('m1'), findsNothing);
    });

    testWidgets('scrolling the list closes the row', (tester) async {
      await pump(tester, chatWith(many(40)));
      final start = left(tester, bubble('m39'));
      await open(tester, 'm39');

      // Scroll by a little, from another bubble, so m39 stays on screen.
      await tester.drag(bubble('m36'), const Offset(0, 80));
      await tester.pumpAndSettle();

      expect(bubble('m39'), findsOneWidget);
      expect(row('m39'), findsNothing);
      expect(left(tester, bubble('m39')), start);
    });
  });

  group('each box runs its action and closes the row', () {
    testWidgets('reply opens the reply bar', (tester) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      await open(tester, 'm1');
      await tester.tap(box('reply'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
      expect(find.text('Replying to Bob'), findsOneWidget);
      expect(row('m1'), findsNothing);
    });

    testWidgets('forward opens the forward picker', (tester) async {
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      await open(tester, 'm1');
      await tester.tap(box('forward'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('forward-c2')), findsOneWidget);
      expect(row('m1'), findsNothing);
    });

    testWidgets('edit opens the edit bar with the text', (tester) async {
      await pump(tester, chatWith([msg('m1', body: 'typo hre')]));
      await open(tester, 'm1');
      await tester.tap(box('edit'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-bar')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('composer-field')),
      );
      expect(field.controller!.text, 'typo hre');
      expect(row('m1'), findsNothing);
    });

    testWidgets('delete asks first, then deletes for everyone', (tester) async {
      final chat = chatWith([msg('m1')]);
      await pump(tester, chat);
      await open(tester, 'm1');
      await tester.tap(box('delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-confirm')), findsOneWidget);
      expect(row('m1'), findsNothing);
      expect(chat.deleted, isEmpty, reason: 'nothing before the confirm');

      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(chat.deleted, ['m1']);
    });

    testWidgets('read-by opens who has read it', (tester) async {
      final chat = chatWith([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: bob.userId, shares: true, readAt: DateTime.now()),
        ];
      await pump(tester, chat, group: true);
      await open(tester, 'm1');
      await tester.tap(box('read-by'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('readers')), findsOneWidget);
      expect(find.byKey(ValueKey('reader-${bob.userId}')), findsOneWidget);
      expect(row('m1'), findsNothing);
    });
  });

  group('a screen reader gets the same actions', () {
    const labels = {
      'readBy': 'Read by',
      'reply': 'Reply',
      'forward': 'Forward',
      'edit': 'Edit',
      'delete': 'Delete for everyone',
    };

    testWidgets('per message kind, one action per allowed box', (tester) async {
      final handle = tester.ensureSemantics();
      final old = DateTime.now().subtract(const Duration(hours: 7));
      final chat =
          chatWith([
              msg('own', body: 'mine fresh'),
              msg('old', body: 'mine old', createdAt: old),
              msg('fwd', body: 'mine forwarded', forwarded: true),
              msg('bob', body: 'from bob', from: bob.userId),
              msg('del', body: '', deletion: MessageDeletion.placeholder),
            ])
            ..store('c1/1.png')
            ..history['c1']!.add(
              msg('pic', from: bob.userId, body: '', photo: 'c1/1.png'),
            );
      await pump(tester, chat, group: true);

      expect(
        actionLabels(actionsNode(tester, bubble('own'))),
        unorderedEquals(labels.values),
      );
      expect(
        actionLabels(actionsNode(tester, bubble('old'))),
        unorderedEquals(['Read by', 'Reply', 'Forward']),
      );
      expect(
        actionLabels(actionsNode(tester, bubble('fwd'))),
        unorderedEquals(['Read by', 'Reply', 'Forward', 'Delete for everyone']),
      );
      expect(
        actionLabels(actionsNode(tester, bubble('bob'))),
        unorderedEquals(['Reply', 'Forward']),
      );
      expect(
        actionLabels(actionsNode(tester, bubble('pic'))),
        unorderedEquals(['Reply', 'Forward']),
      );
      expect(
        actionsNode(tester, find.byKey(const ValueKey('deleted-del'))),
        isNull,
      );
      handle.dispose();
    });

    testWidgets('none on a pending photo', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, chatWith([msg('m1', pending: true)]), settle: false);
      expect(actionsNode(tester, bubble('m1')), isNull);
      handle.dispose();
    });

    testWidgets('Reply runs the reply', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      invoke(actionsNode(tester, bubble('m1'))!, 'Reply');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Forward runs the forward', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, chatWith([msg('m1', from: bob.userId)]));
      invoke(actionsNode(tester, bubble('m1'))!, 'Forward');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('forward-c2')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Edit runs the edit', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, chatWith([msg('m1')]));
      invoke(actionsNode(tester, bubble('m1'))!, 'Edit');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-bar')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Delete for everyone asks, then deletes', (tester) async {
      final handle = tester.ensureSemantics();
      final chat = chatWith([msg('m1')]);
      await pump(tester, chat);
      invoke(actionsNode(tester, bubble('m1'))!, 'Delete for everyone');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(chat.deleted, ['m1']);
      handle.dispose();
    });

    testWidgets('Read by opens the readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, chatWith([msg('m1')]), group: true);
      invoke(actionsNode(tester, bubble('m1'))!, 'Read by');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('readers')), findsOneWidget);
      handle.dispose();
    });
  });

  group('SwipeableMessage on its own', () {
    Future<({ValueNotifier<String?> openId, List<Object> events})> mount(
      WidgetTester tester,
      List<MessageAction> actions,
    ) async {
      final openId = ValueNotifier<String?>(null);
      addTearDown(openId.dispose);
      final events = <Object>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SwipeableMessage(
                messageId: 'x',
                mine: false,
                actions: actions,
                openId: openId,
                onOpenChanged: (open) {
                  events.add(open);
                  openId.value = open ? 'x' : null;
                },
                onAction: events.add,
                child: Container(
                  key: const ValueKey('message-x'),
                  width: 200,
                  height: 40,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
      return (openId: openId, events: events);
    }

    testWidgets('with no actions it renders the child unwrapped: no swipe, '
        'no screen-reader actions', (tester) async {
      final handle = tester.ensureSemantics();
      final m = await mount(tester, const []);
      final start = left(tester, bubble('x'));
      expect(actionsNode(tester, bubble('x')), isNull);

      final g = await tester.startGesture(tester.getCenter(bubble('x')));
      await g.moveBy(const Offset(20, 0));
      await g.moveBy(const Offset(80, 0));
      await tester.pump();
      expect(left(tester, bubble('x')), start);
      await g.up();
      await tester.pumpAndSettle();
      expect(m.events, isEmpty);
      expect(row('x'), findsNothing);
      handle.dispose();
    });

    testWidgets('dragging an open bubble either way reports nothing and '
        'leaves it open', (tester) async {
      final m = await mount(tester, const [MessageAction.reply]);
      await open(tester, 'x');
      expect(m.events, [true]);
      // Centred here, so the open row can shift the resting x: measure it.
      final rest = left(tester, bubble('x'));

      await tester.drag(bubble('x'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.drag(bubble('x'), swipeOpen);
      await tester.pumpAndSettle();

      expect(m.events, [true], reason: 'no close, no second open');
      expect(row('x'), findsOneWidget);
      expect(left(tester, bubble('x')), rest);
    });

    testWidgets('opening reports it, a box reports its action, and another '
        'id opening closes it', (tester) async {
      final m = await mount(tester, const [
        MessageAction.reply,
        MessageAction.forward,
      ]);
      final start = left(tester, bubble('x'));

      await open(tester, 'x');
      expect(m.events, [true]);
      expect(shownBoxes(), ['reply', 'forward']);

      await tester.tap(box('forward'));
      await tester.pumpAndSettle();
      expect(m.events, contains(MessageAction.forward));

      // Closing on an action is the screen's call (covered above); here
      // the parent says another message is now the open one.
      m.openId.value = 'someone-else';
      await tester.pumpAndSettle();
      expect(row('x'), findsNothing);
      expect(left(tester, bubble('x')), start);
    });
  });
}
