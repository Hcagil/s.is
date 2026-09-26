// A message bubble hugs its content: a short text gets a narrow bubble, a
// long one wraps at a 320-wide content column. The time ("HH:MM", or
// "edited HH:MM") sits on its own line under the body, right-aligned, inside
// the bubble; a deleted message shows none. Nothing overflows at text scale
// 3. Written from that contract only: the bubble is whatever is keyed
// `message-<id>`, and every padding/margin figure is measured from the
// rendered tree, never copied from the widget code.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

/// The content column's cap, from the contract.
const cap = 320.0;

final today = DateTime.now();

/// 09:41 local today (a UTC instant, as the repository hands it over).
final sentAt = DateTime(today.year, today.month, today.day, 9, 41).toUtc();
const shownAt = '09:41';

const short = 'hi';
const long =
    'This is a long message, long enough that it has to wrap onto several '
    'lines inside its bubble on any phone, and certainly wider than the '
    'three hundred and twenty pixel content column of a message bubble.';

Message msg(
  String id,
  String body, {
  String from = 'u1',
  DateTime? editedAt,
  MessageDeletion? deletion,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: sentAt,
  editedAt: editedAt,
  deletion: deletion,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> pump(
  WidgetTester tester,
  List<Message> history, {
  Size size = const Size(800, 1200),
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final chat = ChatFake(self: me.userId)..history['c1'] = history;
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
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'something overflowed');
}

Finder bubble(String id) => find.byKey(ValueKey('message-$id'));

Finder inBubble(String id, Finder f) =>
    find.descendant(of: bubble(id), matching: f);

/// The body's paragraph in bubble [id].
Finder body(String id, String text) => inBubble(id, find.text(text));

/// Every text widget in bubble [id] that is part of the time line: the time
/// itself and, when edited, the "edited" mark (one widget or two).
Finder timeLine(String id) => inBubble(
  id,
  find.byWidgetPredicate((w) {
    final s = switch (w) {
      Text(:final data?) => data,
      Text(:final textSpan?) => textSpan.toPlainText(),
      _ => null,
    };
    return s != null && (s.contains(shownAt) || s.trim() == 'edited');
  }),
);

/// The union of every rect [f] finds.
Rect span(WidgetTester tester, Finder f) {
  final rects = [
    for (final e in f.evaluate())
      tester.getRect(find.byElementPredicate((x) => x == e)),
  ];
  expect(rects, isNotEmpty, reason: '$f found nothing');
  return rects.reduce((a, b) => a.expandToInclude(b));
}

/// Horizontal room the bubble adds around its content (padding, border,
/// margin): the bubble's width minus the width of what it holds.
double chrome(WidgetTester tester, String id, String text) {
  // Widths, not the union of rects: the time is right-aligned, so a union
  // spans the whole column even when the column is wrongly stretched.
  final content = [
    span(tester, body(id, text)).width,
    span(tester, timeLine(id)).width,
  ].reduce((a, b) => a > b ? a : b);
  return tester.getSize(bubble(id)).width - content;
}

void expectInside(Rect inner, Rect outer, String what) {
  expect(
    outer.left - 0.5 <= inner.left &&
        inner.right <= outer.right + 0.5 &&
        outer.top - 0.5 <= inner.top &&
        inner.bottom <= outer.bottom + 0.5,
    isTrue,
    reason: '$what $inner is not inside the bubble $outer',
  );
}

/// The time line is under the body, right-aligned with the content, inside
/// the bubble.
void expectTimeUnderBody(WidgetTester tester, String id, String text) {
  final b = tester.getRect(bubble(id));
  final p = span(tester, body(id, text));
  final t = span(tester, timeLine(id));
  expectInside(p, b, 'the body');
  expectInside(t, b, 'the time');
  expect(
    t.top,
    greaterThanOrEqualTo(p.bottom - 0.5),
    reason: 'the time $t is not on its own line under the body $p',
  );
  final right = p.right > t.right ? p.right : t.right;
  expect(
    t.right,
    closeTo(right, 0.5),
    reason: 'the time $t is not right-aligned with the content (body $p)',
  );
}

void main() {
  for (final (who, from) in [
    ('my own', me.userId),
    ('a received', bob.userId),
  ]) {
    group('$who message', () {
      testWidgets('a short text hugs a narrow bubble; a long one caps at the '
          'content column', (tester) async {
        await pump(tester, [
          msg('s', short, from: from),
          msg('l', long, from: from),
        ]);

        final s = tester.getSize(bubble('s')).width;
        final l = tester.getSize(bubble('l')).width;
        expect(
          s,
          lessThan(l / 2),
          reason:
              '"$short" gets a $s-wide bubble, "long" $l: it does not hug its content',
        );

        // The long body wraps, and at the cap, not narrower.
        final para = tester.renderObject<RenderParagraph>(body('l', long));
        expect(
          para.size.width,
          lessThanOrEqualTo(cap + 0.5),
          reason: 'the content column is capped at $cap',
        );
        expect(
          para.size.width,
          greaterThan(cap * 0.85),
          reason: 'a long text uses the column',
        );
        expect(
          para.size.height,
          greaterThan(
            tester.renderObject<RenderParagraph>(body('s', short)).size.height *
                2,
          ),
          reason: 'a long text wraps',
        );

        // The bubble is the capped column plus the same chrome a short
        // bubble adds around its content: never wider.
        final around = chrome(tester, 's', short);
        expect(
          around,
          inInclusiveRange(0, 64),
          reason: 'measured chrome $around',
        );
        expect(l, lessThanOrEqualTo(cap + around + 0.5));
        expect(
          chrome(tester, 'l', long),
          closeTo(around, 0.5),
          reason: 'the same bubble chrome for both',
        );
      });

      testWidgets(
        'a medium text: the bubble is exactly its content plus chrome',
        (tester) async {
          const medium = 'see you soon';
          await pump(tester, [
            msg('s', short, from: from),
            msg('m', medium, from: from),
          ]);
          final para = tester.renderObject<RenderParagraph>(body('m', medium));
          final painter = TextPainter(
            text: para.text,
            textDirection: TextDirection.ltr,
            textScaler: para.textScaler,
          )..layout();
          expect(
            para.size.width,
            closeTo(painter.width, 1),
            reason: 'the body is not stretched',
          );
          painter.dispose();
          expect(
            chrome(tester, 'm', medium),
            closeTo(chrome(tester, 's', short), 0.5),
          );
        },
      );

      testWidgets('the time is on its own line under the body, right-aligned', (
        tester,
      ) async {
        await pump(tester, [
          msg('s', short, from: from),
          msg('l', long, from: from),
        ]);
        for (final (id, text) in [('s', short), ('l', long)]) {
          expectTimeUnderBody(tester, id, text);
        }
      });

      testWidgets('"edited HH:MM" is on that same line', (tester) async {
        final edited = sentAt.add(const Duration(minutes: 1));
        await pump(tester, [
          msg('s', short, from: from, editedAt: edited),
          msg('l', long, from: from, editedAt: edited),
        ]);
        for (final (id, text) in [('s', short), ('l', long)]) {
          final line = timeLine(id);
          final all = [
            for (final e in line.evaluate())
              (e.widget as Text).data ??
                  (e.widget as Text).textSpan!.toPlainText(),
          ].join(' ');
          expect(
            all,
            matches(RegExp(r'edited\s+' + shownAt)),
            reason: 'bubble $id: "$all"',
          );
          expectTimeUnderBody(tester, id, text);
          final rects = [
            for (final e in line.evaluate())
              tester.getRect(find.byElementPredicate((x) => x == e)),
          ];
          for (final r in rects) {
            expect(
              r.center.dy,
              closeTo(rects.first.center.dy, 2),
              reason: '"edited" and the time on one line',
            );
          }
        }
      });

      testWidgets('a deleted message shows no time', (tester) async {
        await pump(tester, [
          msg('d', '', from: from, deletion: MessageDeletion.placeholder),
        ]);
        expect(bubble('d'), findsOneWidget);
        final texts = [
          for (final e in inBubble('d', find.byType(RichText)).evaluate())
            (e.widget as RichText).text.toPlainText(),
        ].join(' ');
        expect(texts, isNot(contains(shownAt)));
        expect(texts, isNot(contains('edited')));
      });

      for (final (id, text) in [('s', short), ('l', long)]) {
        testWidgets('text scale 3 on a narrow phone, "$id": nothing overflows, '
            'the time stays inside', (tester) async {
          await pump(
            tester,
            [msg(id, text, from: from, editedAt: sentAt)],
            size: const Size(320, 3000),
            textScale: 3,
          );
          expectTimeUnderBody(tester, id, text);
          final b = tester.getRect(bubble(id));
          expect(
            b.left >= -0.5 && b.right <= 320.5,
            isTrue,
            reason: 'bubble $id $b is off screen',
          );
        });
      }
    });
  }
}
