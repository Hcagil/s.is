// A zoomed photo hands its extra sideways drag to the pages, from the
// contract:
//
// 1. zoomed, a one-finger sideways drag pans inside the photo while it has
//    room; the page does not move;
// 2. at the left edge a further drag right brings the previous photo in with
//    the finger; at the right edge, the next photo the same way;
// 3. released past half the viewport, or flung faster than 300 px/s toward
//    the incoming page, it settles there in about 200 ms and viewer-position
//    changes only after the settle; a shorter slow drag springs back, same
//    page, still zoomed;
// 4. first photo + drag right, last photo + drag left: no page movement;
// 5. after a page change the photo left behind is at fit, the new one too;
// 6. two fingers never change page; zoomed, no swipe-down;
// 7. only a sideways drag hands over: panning past the top or bottom edge
//    does nothing new.
// Keys: viewer-pages, viewer-image-$path, viewer-position ("n of m").
//
// Geometry: the test screen is 800x600, so a page is 800 wide and half the
// viewport is 400 px. Edges are not assumed: a pan runs until the zoom
// matrix stops moving. Page movement is read from the InteractiveViewer box
// (it moves with its page; the zoom moves only its child). Every drag
// carries pointer timestamps so the release velocity is the one chosen here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';

const a = 'c1/a.png';
const b = 'c1/b.png';
const c = 'c1/c.png';
const paths = [a, b, c];
const centre = Offset(400, 300);

Finder inViewer(Finder f) =>
    find.descendant(of: find.byType(PhotoViewer), matching: f);
Finder image(String path) =>
    inViewer(find.byKey(ValueKey('viewer-image-$path')));
Finder viewerOf(String path) => find
    .ancestor(of: image(path), matching: find.byType(InteractiveViewer))
    .first;

Future<void> open(WidgetTester t, int index) async {
  final chat = ChatFake();
  for (final p in paths) {
    chat.store(p, photoPng);
  }
  await t.pumpWidget(
    ProviderScope(
      overrides: [chatRepositoryProvider.overrideWithValue(chat)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => openPhotoViewer(context, paths, index),
                child: const Text('chat behind'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('chat behind'));
  await t.pumpAndSettle();
  await settleImages(t);
  expect(image(paths[index]), findsOneWidget);
  rest = pageLeft(t, paths[index]);
}

/// Where a page sits when it is the one shown (set by [open]).
var rest = 0.0;

/// Where the page holding [path] sits on screen.
double pageLeft(WidgetTester t, String path) => t.getTopLeft(viewerOf(path)).dx;

Matrix4 matrix(WidgetTester t, String path) =>
    t.widget<InteractiveViewer>(viewerOf(path)).transformationController!.value;
double scale(WidgetTester t, String path) =>
    matrix(t, path).getMaxScaleOnAxis();
double tx(WidgetTester t, String path) => matrix(t, path).getTranslation().x;
double ty(WidgetTester t, String path) => matrix(t, path).getTranslation().y;

/// Where the photo sits on screen (the zoom and the page offset included).
double left(WidgetTester t, String path) => t.getTopLeft(image(path)).dx;
double topOf(WidgetTester t, String path) => t.getTopLeft(image(path)).dy;

/// Whether any of the page holding [path] is on screen.
bool shown(WidgetTester t, String path) {
  if (image(path).evaluate().isEmpty) return false;
  final r = t.getRect(viewerOf(path));
  return r.right > 1 && r.left < 799;
}

/// The counter's numbers as "n / m" (its words are localised: "2 of 3").
String position(WidgetTester t) =>
    RegExp(r'\d+').allMatches(_counter(t)).map((m) => m[0]).join(' / ');
String _counter(WidgetTester t) => t
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('viewer-position')),
            matching: find.byType(Text),
            matchRoot: true,
          )
          .first,
    )
    .data!;

double page(WidgetTester t) => t
    .widget<PageView>(
      find.descendant(
        of: find.byKey(const ValueKey('viewer-pages')),
        matching: find.byType(PageView),
        matchRoot: true,
      ),
    )
    .controller!
    .page!;

double alpha(WidgetTester t) => t
    .widget<Scaffold>(inViewer(find.byType(Scaffold)).first)
    .backgroundColor!
    .a;

Future<void> zoomIn(WidgetTester t, String path) async {
  await t.tapAt(centre);
  await t.pump(const Duration(milliseconds: 80));
  await t.tapAt(centre);
  await t.pumpAndSettle();
  expect(scale(t, path), closeTo(2.5, 0.01), reason: 'double-tap did not zoom');
}

/// The pointer clock: velocity is estimated from event timestamps.
var clock = Duration.zero;

Future<TestGesture> press(WidgetTester t, {int pointer = 1}) async {
  clock = Duration.zero;
  return t.startGesture(centre, pointer: pointer);
}

Future<void> step(WidgetTester t, TestGesture g, Offset by, int ms) async {
  clock += Duration(milliseconds: ms);
  await g.moveBy(by, timeStamp: clock);
  await t.pump(Duration(milliseconds: ms));
}

/// [n] steps of [by] every [ms] ms.
Future<void> steps(
  WidgetTester t,
  TestGesture g,
  Offset by,
  int n, {
  int ms = 20,
}) async {
  for (var i = 0; i < n; i++) {
    await step(t, g, by, ms);
  }
}

/// Moves [by] every 20 ms until [read] (a pan coordinate) stops changing:
/// the photo is at its edge. Returns that coordinate.
Future<double> panToEdge(
  WidgetTester t,
  TestGesture g,
  Offset by,
  double Function() read,
) async {
  await steps(t, g, by, 3); // past the touch slop
  final start = read();
  var last = start;
  for (var i = 0; i < 300; i++) {
    await step(t, g, by, 20);
    final now = read();
    if ((now - last).abs() < 0.01 && (now - start).abs() > 50) return now;
    last = now;
  }
  fail('the photo never reached its edge');
}

/// The x pan at the edge reached by the last [atRightEdge]/[atLeftEdge].
var edgeTx = 0.0;

/// Holds the finger still, so the release reads as no fling, and lifts it.
Future<void> holdAndLift(WidgetTester t, TestGesture g) async {
  await step(t, g, Offset.zero, 100);
  await step(t, g, Offset.zero, 100);
  await g.up(timeStamp: clock);
}

const leftward = Offset(-10, 0);
const rightward = Offset(10, 0);

/// Opens photo [index] zoomed and drags until the photo is at its right
/// edge (the finger moving left); the finger stays down.
Future<TestGesture> atRightEdge(WidgetTester t, int index) async {
  await open(t, index);
  await zoomIn(t, paths[index]);
  final g = await press(t);
  edgeTx = await panToEdge(t, g, leftward, () => tx(t, paths[index]));
  return g;
}

Future<TestGesture> atLeftEdge(WidgetTester t, int index) async {
  await open(t, index);
  await zoomIn(t, paths[index]);
  final g = await press(t);
  edgeTx = await panToEdge(t, g, rightward, () => tx(t, paths[index]));
  return g;
}

void main() {
  testWidgets('1. zoomed, a sideways drag with room left pans the photo and '
      'the page stays put', (t) async {
    await open(t, 1);
    await zoomIn(t, b);
    final before = tx(t, b);
    final g = await press(t);
    for (var i = 0; i < 40; i++) {
      await step(t, g, leftward, 20);
      expect(page(t), 1, reason: 'the page moved while the photo had room');
      expect(shown(t, c), isFalse, reason: 'the next photo came in early');
    }
    expect(tx(t, b) - before, lessThan(-350), reason: 'the photo did not pan');
    expect(pageLeft(t, b), closeTo(rest, 0.5), reason: 'the page moved');
    for (var i = 0; i < 40; i++) {
      await step(t, g, rightward, 20);
      expect(page(t), 1, reason: 'the page moved while the photo had room');
      expect(shown(t, a), isFalse, reason: 'the previous photo came in early');
    }
    await holdAndLift(t, g);
    await t.pumpAndSettle();
    expect(position(t), '2 / 3');
    expect(scale(t, b), closeTo(2.5, 0.01));
  });

  testWidgets('2. at the right edge, dragging on brings the next photo in '
      'with the finger', (t) async {
    final g = await atRightEdge(t, 1);
    expect(shown(t, c), isFalse);
    await steps(t, g, leftward, 3);
    final b0 = pageLeft(t, b);
    await steps(t, g, leftward, 10);
    expect(pageLeft(t, b) - b0, closeTo(-100, 12), reason: 'b did not follow');
    expect(shown(t, c), isTrue, reason: 'the next photo is not on screen');
    expect(
      pageLeft(t, c),
      closeTo(pageLeft(t, b) + 800, 2),
      reason: 'c not beside b',
    );
    expect(position(t), '2 / 3', reason: 'the counter moved during the drag');
    await steps(t, g, rightward, 5);
    expect(
      pageLeft(t, b) - b0,
      closeTo(-50, 12),
      reason: 'b did not follow back',
    );
    await holdAndLift(t, g);
    await t.pumpAndSettle();
  });

  testWidgets('2. at the left edge, dragging on brings the previous photo in '
      'with the finger', (t) async {
    final g = await atLeftEdge(t, 1);
    expect(shown(t, a), isFalse);
    await steps(t, g, rightward, 3);
    final b0 = pageLeft(t, b);
    await steps(t, g, rightward, 10);
    expect(pageLeft(t, b) - b0, closeTo(100, 12), reason: 'b did not follow');
    expect(shown(t, a), isTrue, reason: 'the previous photo is not on screen');
    expect(
      pageLeft(t, a),
      closeTo(pageLeft(t, b) - 800, 2),
      reason: 'a not beside b',
    );
    expect(position(t), '2 / 3', reason: 'the counter moved during the drag');
    await holdAndLift(t, g);
    await t.pumpAndSettle();
  });

  testWidgets('3. released slowly past half the width, it settles on the '
      'next photo in about 200 ms; the counter changes after the settle', (
    t,
  ) async {
    final g = await atRightEdge(t, 1);
    await steps(t, g, leftward, 45); // 450 px past the edge, > 400
    expect(pageLeft(t, c), lessThan(rest + 400), reason: 'not past half');
    await holdAndLift(t, g);
    await t.pump();
    expect(position(t), '2 / 3');
    await t.pump(const Duration(milliseconds: 60));
    expect(pageLeft(t, c), greaterThan(rest + 1), reason: 'settled at once');
    expect(position(t), '2 / 3', reason: 'counter changed before the settle');
    await t.pump(const Duration(milliseconds: 90));
    expect(position(t), '2 / 3', reason: 'counter changed before the settle');
    await t.pump(const Duration(milliseconds: 250));
    expect(pageLeft(t, c), closeTo(rest, 0.5), reason: 'not settled by 400 ms');
    expect(shown(t, b), isFalse);
    await t.pump();
    expect(position(t), '3 / 3', reason: 'the counter did not follow');
    await t.pumpAndSettle();
    expect(position(t), '3 / 3');
  });

  testWidgets('3. released slowly past half the width toward the previous '
      'photo, it settles there', (t) async {
    final g = await atLeftEdge(t, 1);
    await steps(t, g, rightward, 45);
    await holdAndLift(t, g);
    await t.pumpAndSettle();
    expect(pageLeft(t, a), closeTo(rest, 0.5));
    expect(position(t), '1 / 3');
  });

  testWidgets('3. a short fast fling (2000 px/s) past the edge moves to the '
      'next photo', (t) async {
    final g = await atRightEdge(t, 1);
    await steps(t, g, const Offset(-20, 0), 4, ms: 10);
    expect(pageLeft(t, c), greaterThan(rest + 600), reason: 'not a short drag');
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(pageLeft(t, c), closeTo(rest, 0.5));
    expect(position(t), '3 / 3');
  });

  testWidgets('3. a short fling at 400 px/s (over 300) moves to the next '
      'photo', (t) async {
    final g = await atRightEdge(t, 1);
    await steps(t, g, const Offset(-8, 0), 12); // 8 px / 20 ms
    expect(pageLeft(t, c), greaterThan(rest + 600), reason: 'not a short drag');
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(position(t), '3 / 3', reason: 'a 400 px/s fling did not count');
  });

  testWidgets('3. a short drag at 200 px/s (under 300) springs back, same '
      'photo, still zoomed', (t) async {
    final g = await atRightEdge(t, 1);
    await steps(t, g, const Offset(-4, 0), 25); // 4 px / 20 ms
    expect(shown(t, c), isTrue, reason: 'the drag did not hand over');
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(position(t), '2 / 3', reason: 'a slow short drag changed page');
    expect(shown(t, c), isFalse, reason: 'did not spring back');
    expect(scale(t, b), closeTo(2.5, 0.01), reason: 'no longer zoomed');
    expect(tx(t, b), closeTo(edgeTx, 1), reason: 'the pan moved');
    expect(pageLeft(t, b), closeTo(rest, 0.5), reason: 'not back in place');
  });

  testWidgets('3. a short drag released still springs back, toward the '
      'previous photo too', (t) async {
    final g = await atLeftEdge(t, 1);
    await steps(t, g, rightward, 15);
    expect(shown(t, a), isTrue, reason: 'the drag did not hand over');
    await holdAndLift(t, g);
    await t.pumpAndSettle();
    expect(position(t), '2 / 3');
    expect(shown(t, a), isFalse);
    expect(scale(t, b), closeTo(2.5, 0.01));
  });

  testWidgets('3. a fast flick back, away from the incoming photo, springs '
      'back', (t) async {
    final g = await atRightEdge(t, 1);
    await steps(t, g, const Offset(-4, 0), 50); // 200 px past, slowly
    await steps(t, g, const Offset(20, 0), 3, ms: 10); // 2000 px/s back
    expect(shown(t, c), isTrue, reason: 'flicked all the way back');
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(position(t), '2 / 3', reason: 'a fling away still changed page');
    expect(shown(t, c), isFalse);
  });

  testWidgets('4. the first photo, zoomed at its left edge: dragging right '
      'moves no page', (t) async {
    final g = await atLeftEdge(t, 0);
    for (var i = 0; i < 30; i++) {
      await step(t, g, rightward, 20);
      expect(pageLeft(t, a), closeTo(rest, 0.5), reason: 'the page moved');
      expect(tx(t, a), closeTo(edgeTx, 0.5), reason: 'panned past the edge');
      expect(page(t), 0);
    }
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(position(t), '1 / 3');
    expect(pageLeft(t, a), closeTo(rest, 0.5));
    expect(scale(t, a), closeTo(2.5, 0.01));
  });

  testWidgets('4. the last photo, zoomed at its right edge: dragging left '
      'moves no page', (t) async {
    final g = await atRightEdge(t, 2);
    for (var i = 0; i < 30; i++) {
      await step(t, g, leftward, 20);
      expect(pageLeft(t, c), closeTo(rest, 0.5), reason: 'the page moved');
      expect(tx(t, c), closeTo(edgeTx, 0.5), reason: 'panned past the edge');
      expect(page(t), 2);
    }
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(position(t), '3 / 3');
    expect(pageLeft(t, c), closeTo(rest, 0.5));
    expect(scale(t, c), closeTo(2.5, 0.01));
  });

  testWidgets('5. after handing over, the new photo is at fit and the photo '
      'left behind is back at fit', (t) async {
    final g = await atRightEdge(t, 1);
    await steps(t, g, leftward, 45);
    await holdAndLift(t, g);
    await t.pumpAndSettle();
    await settleImages(t);
    expect(position(t), '3 / 3');
    expect(scale(t, c), closeTo(1, 0.01), reason: 'the new photo is zoomed');
    await t.fling(image(c), const Offset(400, 0), 2000);
    await t.pumpAndSettle();
    await settleImages(t);
    expect(position(t), '2 / 3', reason: 'at fit, the swipe back failed');
    expect(scale(t, b), closeTo(1, 0.01), reason: 'the old zoom survived');
    expect(tx(t, b), closeTo(0, 0.5), reason: 'the old pan survived');
  });

  testWidgets('6. zoomed at the edge, two fingers moving sideways never '
      'change page', (t) async {
    final g = await atRightEdge(t, 1);
    await holdAndLift(t, g);
    await t.pumpAndSettle();
    expect(position(t), '2 / 3', reason: 'setup: the page changed');
    expect(tx(t, b), closeTo(edgeTx, 0.5), reason: 'setup: not at the edge');
    expect(shown(t, c), isFalse, reason: 'setup: did not spring back');
    final g1 = await t.startGesture(centre - const Offset(40, 0), pointer: 7);
    final g2 = await t.startGesture(centre + const Offset(40, 0), pointer: 8);
    await t.pump();
    for (var i = 0; i < 40; i++) {
      await g1.moveBy(leftward);
      await g2.moveBy(leftward);
      await t.pump(const Duration(milliseconds: 16));
      expect(shown(t, c), isFalse, reason: 'two fingers moved the page');
      expect(page(t), 1);
    }
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    expect(position(t), '2 / 3');
  });

  testWidgets('6. not zoomed, a slow drag past half the width still changes '
      'page and a swipe down still closes', (t) async {
    await open(t, 1);
    final g = await press(t);
    await steps(t, g, leftward, 50);
    await holdAndLift(t, g);
    await t.pumpAndSettle();
    expect(position(t), '3 / 3');
    final d = await press(t);
    await steps(t, d, const Offset(0, 10), 30);
    await d.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
  });

  testWidgets('7. zoomed at the bottom edge, dragging on upward does '
      'nothing new', (t) async {
    await open(t, 1);
    await zoomIn(t, b);
    final g = await press(t);
    await panToEdge(t, g, const Offset(0, -10), () => ty(t, b));
    final x0 = left(t, b);
    final y0 = topOf(t, b);
    for (var i = 0; i < 30; i++) {
      await step(t, g, const Offset(0, -10), 20);
      expect(page(t), 1);
      expect(left(t, b), closeTo(x0, 1), reason: 'moved sideways');
      expect(topOf(t, b), closeTo(y0, 1), reason: 'moved past the edge');
      expect(shown(t, a) || shown(t, c), isFalse);
    }
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(position(t), '2 / 3');
    expect(scale(t, b), closeTo(2.5, 0.01));
  });

  testWidgets('7. zoomed at the top edge, dragging on downward neither '
      'closes nor fades nor changes page', (t) async {
    await open(t, 1);
    await zoomIn(t, b);
    final g = await press(t);
    await panToEdge(t, g, const Offset(0, 10), () => ty(t, b));
    final y0 = topOf(t, b);
    for (var i = 0; i < 30; i++) {
      await step(t, g, const Offset(0, 10), 20);
      expect(page(t), 1);
      expect(alpha(t), closeTo(1, 0.001), reason: 'zoomed, it faded');
      expect(topOf(t, b), closeTo(y0, 1), reason: 'moved past the edge');
    }
    await g.up(timeStamp: clock);
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget, reason: 'zoomed, closed');
    expect(position(t), '2 / 3');
  });
}
