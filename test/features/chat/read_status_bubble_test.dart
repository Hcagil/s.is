// The sender's own bubble keeps full brightness and gets a thin yellow edge
// until it is read; once read the edge is still there but transparent, so
// the bubble never changes size. Others' bubbles have no edge. In a group,
// one reader among those who share is enough. Judged the way it is drawn:
// the border of the decorated bubble at `ValueKey('message-$id')`.
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
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final sentAt = DateTime.utc(2026, 9, 25, 12);
final after = sentAt.add(const Duration(minutes: 1));
final before = sentAt.subtract(const Duration(minutes: 1));

Message msg(String id, {String from = 'u1', String conversation = 'c1'}) =>
    Message(
      id: id,
      conversationId: conversation,
      senderId: from,
      body: 'hi $id',
      createdAt: sentAt,
    );

Future<void> pump(
  WidgetTester t,
  ChatFake chat, {
  String id = 'c1',
  bool group = false,
  Brightness brightness = Brightness.light,
}) async {
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
  c.read(openConversationProvider.notifier).open(id);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: sisTheme(brightness),
        home: MessageScreen(title: group ? 'Club' : 'Bob', group: group),
      ),
    ),
  );
  await t.pumpAndSettle();
}

const yellow = Color(0xFFFFD54F);

/// The border drawn around message [id]'s bubble: the outermost decoration
/// at or under `ValueKey('message-$id')`; null when it has none.
Border? edge(WidgetTester t, String id) {
  final bubble = find.byKey(ValueKey('message-$id'));
  expect(bubble, findsOneWidget, reason: 'message $id is not on screen');
  final box =
      find
              .descendant(
                of: bubble,
                matching: find.byType(DecoratedBox),
                matchRoot: true,
              )
              .evaluate()
              .first
              .widget
          as DecoratedBox;
  return (box.decoration as BoxDecoration).border as Border?;
}

List<BorderSide> sides(Border b) => [b.top, b.right, b.bottom, b.left];

/// My bubble's edge is always 1.5 wide on every side -- yellow or not.
void edgeWidth(WidgetTester t, String id) {
  final b = edge(t, id);
  expect(b, isNotNull, reason: 'my bubble $id has no border');
  for (final s in sides(b!)) {
    expect(s.width, 1.5, reason: 'edge width of $id');
  }
}

/// Read, or nothing to show: the same 1.5 edge, transparent.
void normal(WidgetTester t, String id) {
  edgeWidth(t, id);
  for (final s in sides(edge(t, id)!)) {
    expect(s.color, Colors.transparent, reason: '$id should look read');
  }
}

/// Unread: 1.5 wide, yellow on every side.
void unread(WidgetTester t, String id) {
  edgeWidth(t, id);
  for (final s in sides(edge(t, id)!)) {
    expect(s.color, yellow, reason: '$id should look unread');
  }
}

/// Drawn below full brightness: an opacity under 1 between the screen and
/// the bubble, or inside it (the old grey, now gone).
bool dimmed(WidgetTester t, String id) {
  final bubble = find.byKey(ValueKey('message-$id'));
  double of(Element e) => switch (e.widget) {
    final Opacity o => o.opacity,
    final FadeTransition f => f.opacity.value,
    final AnimatedOpacity a => a.opacity,
    _ => 1,
  };
  bool fade(Widget w) =>
      w is Opacity || w is FadeTransition || w is AnimatedOpacity;
  // Only between the screen and the bubble: a route's own transition above
  // the screen is not the bubble's colour.
  final screen = find.byType(MessageScreen).evaluate().single;
  bool insideScreen(Element e) {
    var inside = false;
    e.visitAncestorElements((a) => !(inside = a == screen));
    return inside;
  }

  return [
    ...find
        .ancestor(of: bubble, matching: find.byWidgetPredicate(fade))
        .evaluate()
        .where(insideScreen),
    ...find
        .descendant(of: bubble, matching: find.byWidgetPredicate(fade))
        .evaluate(),
  ].any((e) => of(e) < 1);
}

Size sizeOf(WidgetTester t, String id) =>
    t.getSize(find.byKey(ValueKey('message-$id')));

void main() {
  test('the edge colour is the brand unread edge, the same in both themes', () {
    expect(SisBrand.light.unreadEdge, yellow);
    expect(SisBrand.dark.unreadEdge, yellow);
  });

  group('1:1', () {
    testWidgets('my message has the yellow edge until the other member has '
        'read it, at full brightness', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: before),
        ];
      await pump(t, chat);
      unread(t, 'm1');
      expect(dimmed(t, 'm1'), isFalse, reason: 'unread is no longer grey');
    });

    testWidgets('never read at all: yellow edge', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      unread(t, 'm1');
    });

    testWidgets('read: transparent edge, full brightness', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: after),
        ];
      await pump(t, chat);
      normal(t, 'm1');
      expect(dimmed(t, 'm1'), isFalse);
    });

    testWidgets('the other member does not share (or I do not): normal', (
      t,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
      await pump(t, chat);
      normal(t, 'm1');
    });

    testWidgets('their message has no edge at all', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: 'u2'), msg('m2', from: 'u2')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      expect(edge(t, 'm1'), isNull);
      expect(edge(t, 'm2'), isNull);
      expect(dimmed(t, 'm1'), isFalse);
    });

    testWidgets('read status that cannot be loaded: normal, messages shown', (
      t,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksResult = const Err(NetworkFailure('offline'));
      await pump(t, chat);
      normal(t, 'm1');
    });

    testWidgets('the other member reading it clears the edge, live', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      unread(t, 'm1');

      chat.deliverRead(
        'c1',
        ReadMark(userId: 'u2', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      normal(t, 'm1');
    });

    testWidgets('reading a message does not resize its bubble', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);
      final unreadSize = sizeOf(t, 'm1');

      chat.deliverRead(
        'c1',
        ReadMark(userId: 'u2', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      expect(sizeOf(t, 'm1'), unreadSize);
    });

    testWidgets('an older message read, a newer one not', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([
          Message(
            id: 'old',
            conversationId: 'c1',
            senderId: 'u1',
            body: 'old',
            createdAt: before.subtract(const Duration(minutes: 1)),
          ),
          msg('new'),
        ])
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: before),
        ];
      await pump(t, chat);
      normal(t, 'old');
      unread(t, 'new');
    });
  });

  group('dark theme', () {
    testWidgets('unread: the same yellow edge; theirs: none', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1'), msg('m2', from: 'u2')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat, brightness: Brightness.dark);
      unread(t, 'm1');
      expect(edge(t, 'm2'), isNull);
    });

    testWidgets('read: transparent, and the bubble keeps its size', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1')])
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat, brightness: Brightness.dark);
      final unreadSize = sizeOf(t, 'm1');

      chat.deliverRead(
        'c1',
        ReadMark(userId: 'u2', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      normal(t, 'm1');
      expect(sizeOf(t, 'm1'), unreadSize);
    });
  });

  group('group', () {
    Future<void> inGroup(WidgetTester t, List<ReadMark> marks) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', conversation: 'g1')])
        ..readMarksData['g1'] = marks;
      await pump(t, chat, id: 'g1', group: true);
    }

    testWidgets('no sharer has read it: yellow edge', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: before),
        const ReadMark(userId: 'u3', shares: true),
      ]);
      unread(t, 'm1');
    });

    testWidgets('read by one sharing member, not another: read -- one '
        'reader is enough', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after),
        ReadMark(userId: 'u3', shares: true, readAt: before),
      ]);
      normal(t, 'm1');
    });

    testWidgets('read by one of several sharers: read', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: before),
        const ReadMark(userId: 'u3', shares: true),
        ReadMark(userId: 'u4', shares: true, readAt: after),
        ReadMark(userId: 'u5', shares: true, readAt: before),
      ]);
      normal(t, 'm1');
    });

    testWidgets('read by every sharing member: read', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: after),
        ReadMark(userId: 'u3', shares: true, readAt: after),
      ]);
      normal(t, 'm1');
    });

    testWidgets('a member who does not share is not a reader', (t) async {
      await inGroup(t, [
        ReadMark(userId: 'u2', shares: true, readAt: before),
        const ReadMark(userId: 'u3', shares: false),
      ]);
      unread(t, 'm1');
    });

    testWidgets('nobody shares: normal', (t) async {
      await inGroup(t, const [
        ReadMark(userId: 'u2', shares: false),
        ReadMark(userId: 'u3', shares: false),
      ]);
      normal(t, 'm1');
    });

    testWidgets('the first reader clears the edge, live', (t) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', conversation: 'g1')])
        ..readMarksData['g1'] = const [
          ReadMark(userId: 'u2', shares: true),
          ReadMark(userId: 'u3', shares: true),
        ];
      await pump(t, chat, id: 'g1', group: true);
      unread(t, 'm1');

      chat.deliverRead(
        'g1',
        ReadMark(userId: 'u3', shares: true, readAt: after),
      );
      await t.pumpAndSettle();
      normal(t, 'm1');
    });
  });
}
