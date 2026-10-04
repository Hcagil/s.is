// "Read by", from the product rule and the 0.30.10 contract: your
// own message offers "Read by" (0.30.13: first in the tap card and a
// screen-reader action), which opens a floating card (key readers)
// ABOVE the bubble -- in a group a title ("Read by N" / "Nobody yet") and one
// row per reader (reader-<userId>) with the local date or time, height
// capped at 320 with the rows scrolling; in a 1:1 the same card holds one
// line (readers-line), "Read HH:mm" or "Not read yet". Only members who
// share read status can be listed. A tap outside or Back closes it. Run
// under TZ=JST-9 like every unit test: the times below are UTC instants
// whose local date differs from their UTC date.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');
const dee = Member(userId: 'u4', displayName: 'Dee');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// Long ago, so the label is a date and does not move with the clock.
final sentAt = DateTime.utc(2020, 1, 1, 10);
// 20:30 UTC on the 1st is 05:30 on the 2nd in Tokyo.
final bobRead = DateTime.utc(2020, 1, 1, 20, 30);
final cemRead = DateTime.utc(2020, 1, 3, 9);

Message msg(String from) => Message(
  id: 'm1',
  conversationId: 'g1',
  senderId: from,
  body: 'hello club',
  createdAt: sentAt,
);

Future<void> pump(
  WidgetTester t,
  List<ReadMark> marks, {
  String from = 'u1',
  bool group = true,
  List<Member> others = const [bob, cem, dee],
  DateTime? sent,
}) async {
  final chat = ChatFake()
    ..messagesResult = Ok([
      Message(
        id: 'm1',
        conversationId: 'g1',
        senderId: from,
        body: 'hello club',
        createdAt: sent ?? sentAt,
      ),
    ])
    ..membersResult = Ok(others)
    ..readMarksData['g1'] = marks;
  chat.roster['g1'] = [me, ...others];
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  c.read(openConversationProvider.notifier).open('g1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: MessageScreen(title: 'Club', group: group),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> touch(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('message-m1')));
  await t.pumpAndSettle();
}

/// Opens the card through the bubble's screen-reader action. The tap card
/// path is its own test ("reachable from the tap card").
Future<void> openReadBy(WidgetTester t) async {
  final handle = t.ensureSemantics();
  final node = actionsNode(t, find.byKey(const ValueKey('message-m1')));
  expect(
    actionLabels(node),
    contains('Read by'),
    reason: 'no "Read by" offered',
  );
  invokeAction(node!, 'Read by');
  await t.pumpAndSettle();
  handle.dispose();
}

Finder get card => find.byKey(const ValueKey('readers'));

String titleText(WidgetTester t) => t
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('readers-title')),
        matching: find.byType(Text),
        matchRoot: true,
      ),
    )
    .map((w) => w.data ?? '')
    .join(' ');

/// Every text in [row], joined.
String textsIn(WidgetTester t, Finder row) => t
    .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join(' ');

/// The card says "Nobody yet" and claims no count.
void expectNobodyYet() {
  expect(
    find.descendant(of: card, matching: find.text('Nobody yet')),
    findsOneWidget,
  );
  expect(find.textContaining(RegExp(r'Read by \d')), findsNothing);
}

void main() {
  group('a group', () {
    testWidgets('lists each member who has read it, with the local date', (
      t,
    ) async {
      await pump(t, [
        ReadMark(userId: 'u2', shares: true, readAt: bobRead),
        ReadMark(userId: 'u3', shares: true, readAt: cemRead),
      ]);
      await openReadBy(t);

      expect(card, findsOneWidget);
      expect(titleText(t), 'Read by 2');
      final bobRow = find.byKey(const ValueKey('reader-u2'));
      final cemRow = find.byKey(const ValueKey('reader-u3'));
      expect(bobRow, findsOneWidget);
      expect(cemRow, findsOneWidget);
      expect(textsIn(t, bobRow), contains('Bob'));
      expect(
        textsIn(t, bobRow),
        contains('02.01.20'),
        reason: "Bob's time must be the local date, not the UTC one",
      );
      expect(textsIn(t, bobRow), isNot(contains('01.01.20')));
      expect(textsIn(t, cemRow), contains('Cem'));
      expect(textsIn(t, cemRow), contains('03.01.20'));
      expect(find.text('Nobody yet'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('leaves out who read only before it was sent, who never '
        'read, and who does not share', (t) async {
      await pump(t, [
        ReadMark(userId: 'u2', shares: true, readAt: bobRead),
        ReadMark(
          userId: 'u3',
          shares: true,
          readAt: sentAt.subtract(const Duration(days: 1)),
        ),
        const ReadMark(userId: 'u4', shares: false),
      ]);
      await openReadBy(t);

      expect(titleText(t), 'Read by 1');
      expect(find.byKey(const ValueKey('reader-u2')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-u3')), findsNothing);
      expect(find.byKey(const ValueKey('reader-u4')), findsNothing);
      expect(find.text('Cem'), findsNothing);
      expect(find.text('Dee'), findsNothing);
    });

    testWidgets('"Nobody yet" when nobody has read it', (t) async {
      await pump(t, [
        const ReadMark(userId: 'u2', shares: true),
        ReadMark(
          userId: 'u3',
          shares: true,
          readAt: sentAt.subtract(const Duration(minutes: 1)),
        ),
      ]);
      await openReadBy(t);

      expectNobodyYet();
      expect(find.byKey(const ValueKey('reader-u2')), findsNothing);
      expect(find.byKey(const ValueKey('reader-u3')), findsNothing);
    });

    testWidgets('"Nobody yet" when nobody shares read status', (t) async {
      await pump(t, const [
        ReadMark(userId: 'u2', shares: false),
        ReadMark(userId: 'u3', shares: false),
      ]);
      await openReadBy(t);

      expectNobodyYet();
    });

    testWidgets('the card floats above the bubble, inside the screen', (
      t,
    ) async {
      await pump(t, [ReadMark(userId: 'u2', shares: true, readAt: bobRead)]);
      final bubble = t.getRect(find.byKey(const ValueKey('message-m1')));
      await openReadBy(t);

      final box = t.getRect(card);
      expect(
        box.bottom,
        lessThanOrEqualTo(bubble.top),
        reason: 'the card sits above the bubble, not over or under it',
      );
      final screen =
          Offset.zero & t.view.physicalSize / t.view.devicePixelRatio;
      expect(screen.contains(box.topLeft), isTrue);
      expect(screen.contains(box.bottomRight - const Offset(1, 1)), isTrue);
    });

    testWidgets('many readers: at most 320 high and the rows scroll', (
      t,
    ) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final crowd = [
        for (var i = 10; i < 40; i++)
          Member(userId: 'u$i', displayName: 'Reader $i'),
      ];
      await pump(t, [
        for (final m in crowd)
          ReadMark(userId: m.userId, shares: true, readAt: bobRead),
      ], others: crowd);
      // Low on the screen, so the room above it is not what caps the card.
      await openReadBy(t);

      expect(titleText(t), 'Read by 30');
      expect(t.getSize(card).height, lessThanOrEqualTo(320));
      final list = find.descendant(of: card, matching: find.byType(Scrollable));
      expect(list, findsOneWidget, reason: 'the rows do not scroll');
      expect(
        find.byKey(const ValueKey('reader-u39')).hitTestable(),
        findsNothing,
      );
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('reader-u39')),
        100,
        scrollable: list,
      );
      expect(
        find.byKey(const ValueKey('reader-u39')).hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('a tap outside closes it, and nothing else happens', (t) async {
      await pump(t, [ReadMark(userId: 'u2', shares: true, readAt: bobRead)]);
      await openReadBy(t);
      expect(card, findsOneWidget);

      await t.tapAt(const Offset(20, 300));
      await t.pumpAndSettle();

      expect(card, findsNothing);
      expect(find.byKey(const ValueKey('message-menu')), findsNothing);
      expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
    });

    testWidgets('Back closes only the card', (t) async {
      await pump(t, [ReadMark(userId: 'u2', shares: true, readAt: bobRead)]);
      await openReadBy(t);

      await t.binding.handlePopRoute();
      await t.pumpAndSettle();

      expect(card, findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
    });

    testWidgets("someone else's message offers no \"Read by\"", (t) async {
      await pump(t, [
        ReadMark(userId: 'u3', shares: true, readAt: cemRead),
      ], from: 'u2');
      await touch(t);
      expect(
        find.byKey(const ValueKey('menu-reply')),
        findsOneWidget,
        reason: 'the row did open',
      );
      expect(find.byKey(const ValueKey('menu-read-by')), findsNothing);
      final handle = t.ensureSemantics();
      expect(
        actionLabels(actionsNode(t, find.byKey(const ValueKey('message-m1')))),
        isNot(contains('Read by')),
      );
      handle.dispose();
    });

    // 0.30.13: the tap card offers "Read by" first on your own message.
    testWidgets('your own message: "Read by" is reachable from the tap card', (
      t,
    ) async {
      await pump(t, [ReadMark(userId: 'u3', shares: true, readAt: cemRead)]);
      await touch(t);
      expect(find.byKey(const ValueKey('message-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-read-by')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('menu-read-by')));
      await t.pumpAndSettle();
      expect(card, findsOneWidget);
    });
  });

  group('a 1:1 (0.30.10)', () {
    String hhmm(DateTime d) {
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.hour)}:${two(l.minute)}';
    }

    testWidgets('read: the card holds one line, "Read HH:mm" in local time, '
        'and no list', (t) async {
      final sent = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final read = sent.add(const Duration(minutes: 7));
      await pump(
        t,
        [ReadMark(userId: 'u2', shares: true, readAt: read)],
        group: false,
        others: const [bob],
        sent: sent,
      );
      await openReadBy(t);

      expect(card, findsOneWidget);
      final line = find.byKey(const ValueKey('readers-line'));
      expect(line, findsOneWidget);
      expect(
        find.descendant(
          of: line,
          matching: find.text('Read ${hhmm(read)}'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-u2')), findsNothing);
      expect(find.byKey(const ValueKey('readers-title')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the tap card offers "Read by" in a 1:1 too, and it opens '
        'the card', (t) async {
      await pump(
        t,
        const [ReadMark(userId: 'u2', shares: true)],
        group: false,
        others: const [bob],
      );
      await touch(t);
      await t.tap(find.byKey(const ValueKey('menu-read-by')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('readers-line')), findsOneWidget);
    });

    testWidgets('not read: "Not read yet"', (t) async {
      await pump(
        t,
        const [ReadMark(userId: 'u2', shares: true)],
        group: false,
        others: const [bob],
      );
      await openReadBy(t);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('readers-line')),
          matching: find.text('Not read yet'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });
  });
}
