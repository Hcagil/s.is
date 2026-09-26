// A message bubble hugs its content: a short text gets a narrow bubble, a
// long one wraps inside a bubble at most 320 wide (12 px padding each side,
// so a 296-wide content column). The time ("HH:MM", or "edited HH:MM") sits
// on the body's last line, bottom-right, when that line + 6 + the time fits
// the column; otherwise it drops to its own row under the body,
// right-aligned. A deleted message shows none. Nothing overflows at text
// scale 3, and the decision is made at that scale. Written from that
// contract only: the bubble is whatever is keyed `message-<id>`, the body
// `body-<id>`, the time `time-<id>`; every padding/margin figure is measured
// from the rendered tree, never copied from the widget code.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
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

/// The bubble's outer cap, from the contract.
const cap = 320.0;

/// The contract's gap between the body's last line and an inline time.
const gap = 6.0;

final today = DateTime.now();

/// 09:41 local today (a UTC instant, as the repository hands it over).
final sentAt = DateTime(today.year, today.month, today.day, 9, 41).toUtc();
const shownAt = '09:41';

const short = 'ok';
const medium = 'see you soon';
const long =
    'This is a long message, long enough that it has to wrap onto several '
    'lines inside its bubble on any phone, and certainly wider than the '
    'three hundred and twenty pixel content column of a message bubble.';

/// Several lines, the last one short: the time fits beside it.
const shortLast =
    'A first line that is long enough to wrap inside the bubble on its own '
    'and then some more words\nok';

/// One unbreakable word, far wider than any content column.
final unbreakable = 'https://example.com/${'a1b2c3d4e5' * 12}';

Message msg(
  String id,
  String body, {
  String from = 'u1',
  DateTime? at,
  DateTime? editedAt,
  MessageDeletion? deletion,
  String? replyTo,
  bool forwarded = false,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: at ?? sentAt,
  editedAt: editedAt,
  deletion: deletion,
  replyTo: replyTo,
  forwarded: forwarded,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// The message screen as the app mounts it (the app's own theme), with
/// [history] in conversation c1.
Future<void> pump(
  WidgetTester tester,
  List<Message> history, {
  Size size = const Size(800, 1200),
  double textScale = 1,
  bool group = false,
  TextDirection? direction,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final chat = ChatFake(self: me.userId)
    ..history['c1'] = history
    ..roster['c1'] = [me, bob];
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
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        builder: direction == null
            ? null
            : (context, child) =>
                  Directionality(textDirection: direction, child: child!),
        home: MessageScreen(title: group ? 'Club' : 'Bob', group: group),
      ),
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

/// The time label of bubble [id].
Finder time(String id) => inBubble(id, find.byKey(ValueKey('time-$id')));

/// The union of every rect [f] finds.
Rect span(WidgetTester tester, Finder f) {
  final rects = [
    for (final e in f.evaluate())
      tester.getRect(find.byElementPredicate((x) => x == e)),
  ];
  expect(rects, isNotEmpty, reason: '$f found nothing');
  return rects.reduce((a, b) => a.expandToInclude(b));
}

/// The decorated bubble itself (its outermost decoration), without the
/// margin around it.
Rect decorated(WidgetTester tester, String id) => tester.getRect(
  find.descendant(of: bubble(id), matching: find.byType(DecoratedBox)).first,
);

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

/// What the rendered bubble [id] shows, measured: the body's lines (global
/// rects of their glyphs), the time's rect, and the content box.
class Measured {
  Measured(this.tester, this.id, this.text) {
    para = tester.renderObject<RenderParagraph>(body(id, text));
    final n = para.text.toPlainText().length;
    final origin = para.localToGlobal(Offset.zero);
    final byLine = <double, Rect>{};
    for (final b in para.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: n),
    )) {
      final r = b.toRect();
      final k = r.bottom.roundToDouble();
      byLine[k] = byLine[k]?.expandToInclude(r) ?? r;
    }
    lines = [
      for (final k in byLine.keys.toList()..sort()) byLine[k]!.shift(origin),
    ];
    bodyRect = tester.getRect(body(id, text));
    timeRect = tester.getRect(time(id));
    bubbleRect = decorated(tester, id);
    // Padding each side, measured on the left where the body starts.
    pad = bodyRect.left - bubbleRect.left;
  }

  final WidgetTester tester;
  final String id;
  final String text;
  late final RenderParagraph para;
  late final List<Rect> lines;
  late final Rect bodyRect;
  late final Rect timeRect;
  late final Rect bubbleRect;
  late final double pad;

  /// The content column the contract gives: the 320 cap minus padding.
  double get column => cap - 2 * pad;

  double get lastLine => lines.last.width;
  double get timeWidth => timeRect.width;

  /// The widest body line as laid out in the column (not the paragraph's own
  /// width, so a stretched body cannot vouch for itself).
  double get widest {
    final p = TextPainter(
      text: para.text,
      textDirection: TextDirection.ltr,
      textScaler: para.textScaler,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout(maxWidth: column);
    final w = p.width;
    p.dispose();
    return w;
  }

  /// The contract's rule.
  bool get fits => lastLine + gap + timeWidth <= column;

  /// Where the time actually is.
  bool get inline => (timeRect.bottom - bodyRect.bottom).abs() <= 0.5;

  double get contentLeft => bubbleRect.left + pad;
  double get contentRight => bubbleRect.right - pad;

  String get describe =>
      'bubble $id: last line $lastLine + $gap + time $timeWidth vs column '
      '$column (widest $widest); body $bodyRect, time $timeRect, '
      'bubble $bubbleRect';
}

/// Everything the contract says about bubble [id]'s body and time, in
/// either placement. Returns the measurement for further checks.
Measured expectLaidOut(WidgetTester tester, String id, String text) {
  final m = Measured(tester, id, text);
  final why = m.describe;
  expect(m.bubbleRect.width, lessThanOrEqualTo(cap + 0.5), reason: why);
  expectInside(m.bodyRect, m.bubbleRect, 'the body');
  expectInside(m.timeRect, m.bubbleRect, 'the time');
  expect(
    m.timeRect.right,
    closeTo(m.contentRight, 0.5),
    reason: 'the time is not at the content\'s right edge: $why',
  );
  expect(
    m.inline,
    m.fits,
    reason: m.fits
        ? 'the time fits on the last line but is not there: $why'
        : 'the time does not fit on the last line but is there: $why',
  );
  final content = m.contentRight - m.contentLeft;
  if (m.inline) {
    for (final line in m.lines.where(
      (l) => l.bottom > m.timeRect.top + 0.5 && l.top < m.timeRect.bottom,
    )) {
      expect(
        m.timeRect.left,
        greaterThanOrEqualTo(line.right + gap - 0.5),
        reason: 'the time overlaps the body\'s last line $line: $why',
      );
    }
    final want = [m.widest, m.lastLine + gap + m.timeWidth].reduce(maxOf);
    expect(content, closeTo(want, 1), reason: 'content width: $why');
  } else {
    expect(
      m.timeRect.top,
      greaterThanOrEqualTo(m.bodyRect.bottom - 0.5),
      reason: 'the time is not on its own row under the body: $why',
    );
    final want = [m.widest, m.timeWidth].reduce(maxOf);
    expect(content, closeTo(want, 1), reason: 'content width: $why');
  }
  return m;
}

double maxOf(double a, double b) => a > b ? a : b;

/// The exact text of the time label of bubble [id].
String timeText(WidgetTester tester, String id) =>
    tester.widget<Text>(time(id)).data!;

/// The body's and the two time labels' styles and the bubble padding,
/// captured from rendered bubbles, so texts can be sized to sit at the
/// rule's edges at any text scale.
class Styles {
  Styles(WidgetTester tester, String plain, String edited) {
    final m = Measured(tester, plain, short);
    body = _style(m.para.text);
    plainTime = tester.renderObject<RenderParagraph>(time(plain)).text;
    editedTime = tester.renderObject<RenderParagraph>(time(edited)).text;
    column = m.column;
  }

  late final TextStyle? body;
  late final InlineSpan plainTime;
  late final InlineSpan editedTime;
  late final double column;

  static TextStyle? _style(InlineSpan span) {
    var s = span;
    var style = s.style;
    while (s is TextSpan && s.text == null && (s.children ?? []).isNotEmpty) {
      s = s.children!.first;
      style = style?.merge(s.style) ?? s.style;
    }
    return style;
  }

  static double width(InlineSpan span, double scale) {
    final p = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(scale),
    )..layout();
    final w = p.width;
    p.dispose();
    return w;
  }

  /// A one-word text, a scale and an edit state such that [want] holds for
  /// (text width, time width, column) there.
  Edge find(
    String what,
    bool Function(double w, double time, double column, double scale) want, {
    List<double> scales = const [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8],
  }) {
    const pool = 'thequickbrownfoxjumpsoverthelazydog';
    final words = pool * 4;
    for (final scale in scales) {
      for (final edited in [false, true]) {
        final t = width(edited ? editedTime : plainTime, scale);
        for (var a = 0; a < pool.length; a++) {
          for (var b = a + 1; b <= words.length; b++) {
            final text = words.substring(a, b);
            final w = width(TextSpan(text: text, style: body), scale);
            if (w > column) break;
            if (want(w, t, column, scale)) {
              return (text: text, scale: scale, edited: edited);
            }
          }
        }
      }
    }
    fail('no text for "$what" at any of $scales');
  }
}

typedef Edge = ({String text, double scale, bool edited});

/// Captures [Styles] for [from]'s bubbles, then shows [edge] alone at its
/// scale and returns its measurement, after checking its slack (column minus
/// last line minus time, as rendered) is within [lo, hi].
Future<Measured> showEdge(
  WidgetTester tester,
  String from,
  Edge edge,
  double lo,
  double hi,
) async {
  await pump(tester, [
    msg('e', edge.text, from: from, editedAt: edge.edited ? sentAt : null),
  ], textScale: edge.scale);
  final m = Measured(tester, 'e', edge.text);
  final slack = m.column - m.lastLine - m.timeWidth;
  expect(m.lines, hasLength(1), reason: 'fixture: ${m.describe}');
  expect(
    slack,
    inInclusiveRange(lo, hi),
    reason: 'fixture drifted from its edge: ${m.describe}',
  );
  expectLaidOut(tester, 'e', edge.text);
  return m;
}

Future<Styles> styles(WidgetTester tester, String from) async {
  await pump(tester, [
    msg('p', short, from: from),
    msg('q', short, from: from, editedAt: sentAt),
  ]);
  final st = Styles(tester, 'p', 'q');
  // Unmount before the next pump mounts a fresh screen.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  return st;
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

        final ms = expectLaidOut(tester, 's', short);
        final ml = expectLaidOut(tester, 'l', long);
        expect(
          ms.pad,
          inInclusiveRange(12 - 0.5, 14),
          reason: '12 px padding each side (plus a thin edge, if any)',
        );
        expect(ml.pad, closeTo(ms.pad, 0.5));

        // The long body wraps, and at the column, not narrower.
        expect(
          ml.para.size.width,
          lessThanOrEqualTo(ml.column + 0.5),
          reason: 'the content column is capped at ${ml.column}',
        );
        expect(
          ml.para.size.width,
          greaterThan(ml.column * 0.85),
          reason: 'a long text uses the column',
        );
        expect(ml.lines.length, greaterThan(2), reason: 'a long text wraps');
        expect(ml.bubbleRect.width, lessThanOrEqualTo(cap + 0.5));

        // "ok" hugs: one line, the time beside it, and nothing else.
        expect(ms.lines, hasLength(1));
        expect(ms.inline, isTrue, reason: ms.describe);
        expect(
          ms.bubbleRect.width,
          closeTo(ms.lastLine + gap + ms.timeWidth + 2 * ms.pad, 1),
          reason: ms.describe,
        );
        expect(ms.bubbleRect.width, lessThan(cap / 2));
      });

      testWidgets('a medium text: the bubble is its text, the gap and the '
          'time, plus padding', (tester) async {
        await pump(tester, [msg('m', medium, from: from)]);
        final m = expectLaidOut(tester, 'm', medium);
        final painter = TextPainter(
          text: m.para.text,
          textDirection: TextDirection.ltr,
          textScaler: m.para.textScaler,
        )..layout();
        expect(
          m.para.size.width,
          closeTo(painter.width, 1),
          reason: 'the body is not stretched',
        );
        painter.dispose();
        expect(m.lines, hasLength(1));
        expect(m.inline, isTrue, reason: m.describe);
        expect(
          m.timeRect.left - m.lines.last.right,
          closeTo(gap, 0.5),
          reason: 'a $gap px gap between the text and the time: ${m.describe}',
        );
        expect(
          m.bubbleRect.width,
          closeTo(m.lastLine + gap + m.timeWidth + 2 * m.pad, 1),
          reason: m.describe,
        );
      });

      testWidgets('several lines, the last one short: the time beside it', (
        tester,
      ) async {
        await pump(tester, [
          msg('n', shortLast, from: from),
          msg('l', long, from: from),
        ]);
        expectLaidOut(tester, 'l', long);
        final n = expectLaidOut(tester, 'n', shortLast);
        expect(n.lines.length, greaterThan(1));
        expect(n.inline, isTrue, reason: 'short last line: ${n.describe}');
        expect(
          n.bubbleRect.width - 2 * n.pad,
          closeTo(n.widest, 1),
          reason: 'the widest line sets the width: ${n.describe}',
        );
        expect(
          n.timeRect.left - n.lines.last.right,
          greaterThan(gap),
          reason: n.describe,
        );
      });

      testWidgets('a last line too long for the time: the time on its own '
          'row', (tester) async {
        final st = await styles(tester, from);
        final x = st.find(
          'too long',
          (w, t, c, s) => s == 1 && w + gap + t > c + 10 && w < c - 10,
          scales: const [1],
        );
        await pump(tester, [
          msg('x', x.text, from: from, editedAt: x.edited ? sentAt : null),
          msg('y', 'hi\n${x.text}', from: from),
        ]);
        final one = expectLaidOut(tester, 'x', x.text);
        expect(one.inline, isFalse, reason: one.describe);
        final two = expectLaidOut(tester, 'y', 'hi\n${x.text}');
        expect(two.lines, hasLength(2));
        expect(two.inline, isFalse, reason: two.describe);
      });

      testWidgets('fits with the $gap px gap by a hair: inline', (
        tester,
      ) async {
        final st = await styles(tester, from);
        final e = st.find(
          'tight',
          (w, t, c, s) => c - w - t >= gap + 0.25 && c - w - t <= gap + 3,
        );
        final m = await showEdge(tester, from, e, gap + 0.25, gap + 3);
        expect(m.inline, isTrue, reason: m.describe);
      });

      testWidgets('fits only without the $gap px gap: own row', (tester) async {
        final st = await styles(tester, from);
        final e = st.find(
          'gap only',
          (w, t, c, s) => c - w - t >= 0.25 && c - w - t <= gap - 0.25,
        );
        final m = await showEdge(tester, from, e, 0.25, gap - 0.25);
        expect(m.inline, isFalse, reason: m.describe);
      });

      testWidgets('"edited HH:MM" is one label, on the last line when it '
          'fits', (tester) async {
        final edited = sentAt.add(const Duration(minutes: 1));
        await pump(tester, [
          msg('s', short, from: from, editedAt: edited),
          msg('m', medium, from: from, editedAt: edited),
          msg('l', long, from: from, editedAt: edited),
        ]);
        for (final (id, text) in [('s', short), ('m', medium), ('l', long)]) {
          expect(timeText(tester, id), 'edited $shownAt');
          expectLaidOut(tester, id, text);
        }
        expect(Measured(tester, 's', short).inline, isTrue);
      });

      testWidgets('an unbreakable word wider than the column: the time on its '
          'own row, nothing overflows', (tester) async {
        await pump(tester, [msg('u', unbreakable, from: from)]);
        final m = Measured(tester, 'u', unbreakable);
        expect(m.inline, isFalse, reason: m.describe);
        expect(
          m.timeRect.top,
          greaterThanOrEqualTo(m.bodyRect.bottom - 0.5),
          reason: m.describe,
        );
        expect(m.timeRect.right, closeTo(m.contentRight, 0.5));
        expectInside(m.bodyRect, m.bubbleRect, 'the body');
        expectInside(m.timeRect, m.bubbleRect, 'the time');
        expect(m.bubbleRect.width, lessThanOrEqualTo(cap + 0.5));
      });

      testWidgets('body and time are two widgets, each found by its text and '
          'its key', (tester) async {
        final later = sentAt.add(const Duration(minutes: 1)); // 09:42
        await pump(tester, [
          msg('s', short, from: from),
          msg('l', long, from: from, at: later),
        ]);
        expect(find.text(short), findsOneWidget);
        expect(find.text(long), findsOneWidget);
        expect(find.text(shownAt), findsOneWidget);
        expect(find.text('09:42'), findsOneWidget);
        for (final (id, text, at) in [
          ('s', short, shownAt),
          ('l', long, '09:42'),
        ]) {
          expect(find.byKey(ValueKey('body-$id')), findsOneWidget);
          expect(find.byKey(ValueKey('time-$id')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(ValueKey('body-$id')),
              matching: find.text(text),
            ),
            findsOneWidget,
          );
          expect(timeText(tester, id), at);
          expect(
            find.descendant(
              of: find.byKey(ValueKey('body-$id')),
              matching: find.byKey(ValueKey('time-$id')),
            ),
            findsNothing,
            reason: 'the time is not part of the body',
          );
        }
      });

      testWidgets('a deleted message shows no time', (tester) async {
        await pump(tester, [
          msg('d', '', from: from, deletion: MessageDeletion.placeholder),
        ]);
        expect(bubble('d'), findsOneWidget);
        expect(find.byKey(const ValueKey('time-d')), findsNothing);
        final texts = [
          for (final e in inBubble('d', find.byType(RichText)).evaluate())
            (e.widget as RichText).text.toPlainText(),
        ].join(' ');
        expect(texts, isNot(contains(shownAt)));
        expect(texts, isNot(contains('edited')));
      });

      testWidgets('text scale 3: decided at that scale, nothing overflows', (
        tester,
      ) async {
        final st = await styles(tester, from);
        // Too long for the time at scale 3, yet it would fit at scale 1: a
        // rule measured without the scale gets it wrong.
        final flip = st.find(
          'flips at 3',
          (w, t, c, s) => w + gap + t > c + 2 && (w + t) / 3 + gap < c - 20,
          scales: const [3],
        );
        final cases = [
          ('s', short),
          ('m', medium),
          ('l', long),
          ('n', shortLast),
          ('f', flip.text),
        ];
        await pump(
          tester,
          [
            for (final (id, text) in cases)
              msg(
                id,
                text,
                from: from,
                editedAt: id == 'm' || (id == 'f' && flip.edited)
                    ? sentAt
                    : null,
              ),
          ],
          textScale: 3,
          size: const Size(800, 6000),
        );
        for (final (id, text) in cases) {
          expectLaidOut(tester, id, text);
        }
        expect(Measured(tester, 's', short).inline, isTrue);
        final f = Measured(tester, 'f', flip.text);
        expect(f.lines, hasLength(1), reason: f.describe);
        expect(f.inline, isFalse, reason: f.describe);
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
          final m = Measured(tester, id, text);
          expectInside(m.bodyRect, m.bubbleRect, 'the body');
          expectInside(m.timeRect, m.bubbleRect, 'the time');
          expect(m.timeRect.right, closeTo(m.contentRight, 0.5));
          if (m.inline) {
            expect(
              m.timeRect.left,
              greaterThanOrEqualTo(m.lines.last.right + gap - 0.5),
              reason: m.describe,
            );
          } else {
            expect(
              m.timeRect.top,
              greaterThanOrEqualTo(m.bodyRect.bottom - 0.5),
            );
          }
          final b = tester.getRect(bubble(id));
          expect(
            b.left >= -0.5 && b.right <= 320.5,
            isTrue,
            reason: 'bubble $id $b is off screen',
          );
        });
      }

      testWidgets('right-to-left text in the app\'s layout: the time '
          'bottom-right, clear of the text', (tester) async {
        const hebrew = 'שלום';
        const hebrewLong =
            'שלום עולם, מה שלומך היום? '
            'הכל טוב אצלי, תודה רבה ששאלת אותי על זה';
        await pump(tester, [
          msg('s', hebrew, from: from),
          msg('l', hebrewLong, from: from),
        ]);
        expect(expectLaidOut(tester, 's', hebrew).inline, isTrue);
        expectLaidOut(tester, 'l', hebrewLong);
      });

      testWidgets('RTL: the time stays bottom-right and clear of the text', (
        tester,
      ) async {
        await pump(tester, [
          msg('s', short, from: from),
          msg('l', long, from: from),
        ], direction: TextDirection.rtl);
        for (final (id, text) in [('s', short), ('l', long)]) {
          final bodyRect = tester.getRect(body(id, text));
          final t = tester.getRect(time(id));
          final b = decorated(tester, id);
          expectInside(bodyRect, b, 'the body');
          expectInside(t, b, 'the time');
          expect(t.bottom, greaterThanOrEqualTo(bodyRect.bottom - 0.5));
          expect(
            b.right - t.right,
            lessThanOrEqualTo(14.5),
            reason: 'the time $t is not at the bottom-right of $b',
          );
          final m = Measured(tester, id, text);
          for (final line in m.lines.where(
            (l) => l.bottom > t.top + 0.5 && l.top < t.bottom - 0.5,
          )) {
            expect(
              line.right <= t.left + 0.5 || line.left >= t.right - 0.5,
              isTrue,
              reason: 'bubble $id: the time $t overlaps the text $line',
            );
          }
        }
      });

      testWidgets('a forwarded reply in a group: label, sender and quote '
          'above; body and time below, the time bottom-right', (tester) async {
        final other = from == me.userId ? bob.userId : me.userId;
        await pump(tester, [
          msg('a', 'hello, how are you doing today?', from: other),
          msg('r', short, from: from, replyTo: 'a', forwarded: true),
        ], group: true);
        final m = expectLaidOut(tester, 'r', short);
        expect(m.inline, isTrue, reason: m.describe);
        for (final key in [
          'forwarded-r',
          'quote-r',
          if (from != me.userId) 'sender-r',
        ]) {
          final f = find.byKey(ValueKey(key));
          expect(f, findsOneWidget, reason: key);
          final r = tester.getRect(f);
          expect(
            r.bottom,
            lessThanOrEqualTo(m.bodyRect.top + 0.5),
            reason: '$key $r is not above the body ${m.bodyRect}',
          );
          expect(r.bottom, lessThanOrEqualTo(m.timeRect.top + 0.5));
        }
      });
    });
  }
}
