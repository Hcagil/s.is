// Swipe down closes the full-screen photo (0.30.7), from the contract:
//
// - a vertical drag of at most 120 px, released at most 700 px/s, springs
//   back to dy 0; more than 120 px, or a fling faster than 700 px/s, pops;
// - while dragged the viewer's Scaffold fades: alpha = 1 - dy/400, 0..1;
// - once pinched in (scale > 1.01) a vertical drag pans the photo instead;
// - changing page resets the zoom (a swipe down closes again);
// - the route is not opaque: the chat behind stays built.
// Keys: viewer-pages, viewer-position, viewer-image-$path.
//
// Drags are made in small timed steps so the release velocity is the one
// chosen here; dy is measured from the photo's own position on screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';

import '../../support/fakes.dart';

const a = 'c1/a.png';
const b = 'c1/b.png';

Finder inViewer(Finder f) =>
    find.descendant(of: find.byType(PhotoViewer), matching: f);
Finder image(String path) =>
    inViewer(find.byKey(ValueKey('viewer-image-$path')));

Future<void> open(WidgetTester t) async {
  final chat = ChatFake()
    ..store(a, photoPng)
    ..store(b, photoPng);
  await t.pumpWidget(
    ProviderScope(
      overrides: [chatRepositoryProvider.overrideWithValue(chat)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => openPhotoViewer(context, [a, b], 0),
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
  expect(find.byType(PhotoViewer), findsOneWidget);
  expect(image(a), findsOneWidget);
}

double top(WidgetTester t) => t.getTopLeft(image(a)).dy;

double alpha(WidgetTester t) => t
    .widget<Scaffold>(inViewer(find.byType(Scaffold)).first)
    .backgroundColor!
    .a;

/// The pointer clock: velocity is estimated from event timestamps, which a
/// TestGesture leaves at zero unless told.
var clock = Duration.zero;

Future<void> step(WidgetTester t, TestGesture g, double dy, int ms) async {
  clock += Duration(milliseconds: ms);
  await g.moveBy(Offset(0, dy), timeStamp: clock);
  await t.pump(Duration(milliseconds: ms));
}

/// Puts a finger on the photo and moves it past the touch slop, so every
/// later move is all drag.
Future<TestGesture> grab(WidgetTester t) async {
  clock = Duration.zero;
  final g = await t.startGesture(t.getCenter(image(a)));
  await step(t, g, 30, 50);
  return g;
}

/// Moves [g] down by [by] in steps of [px] px every 20 ms: px*50 px/s.
/// (Samples further apart than 40 ms read as a finger that stopped.)
Future<void> drag(WidgetTester t, TestGesture g, double by, double px) async {
  for (var moved = 0.0; moved < by; moved += px) {
    await step(t, g, px, 20);
  }
}

/// Drags down until the photo sits [target] px below where it started, at
/// [px]*50 px/s, and lets go. Returns the dy at the moment of release.
Future<double> dragTo(WidgetTester t, double target, {double px = 4}) async {
  final start = top(t);
  final g = await grab(t);
  await drag(t, g, target - (top(t) - start), px);
  final dy = top(t) - start;
  await g.up();
  await t.pumpAndSettle();
  return dy;
}

double scale(WidgetTester t) => t
    .widget<InteractiveViewer>(inViewer(find.byType(InteractiveViewer)).first)
    .transformationController!
    .value
    .getMaxScaleOnAxis();

Future<void> pinchIn(WidgetTester t) async {
  final c = t.getCenter(image(a));
  final g1 = await t.startGesture(c - const Offset(40, 0), pointer: 7);
  final g2 = await t.startGesture(c + const Offset(40, 0), pointer: 8);
  await t.pump();
  for (var i = 0; i < 10; i++) {
    await g1.moveBy(const Offset(-10, 0));
    await g2.moveBy(const Offset(10, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g1.up();
  await g2.up();
  await t.pumpAndSettle();
  expect(scale(t), greaterThan(1.01), reason: 'the pinch did not zoom');
}

void main() {
  testWidgets('the chat stays built behind the viewer (not opaque)', (t) async {
    await open(t);
    expect(find.text('chat behind'), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-pages')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-position')), findsOneWidget);
  });

  testWidgets('a slow drag (200 px/s) of at most 120 px springs back to dy 0', (
    t,
  ) async {
    await open(t);
    final start = top(t);
    final dy = await dragTo(t, 110);
    expect(dy, inInclusiveRange(90, 120), reason: 'the drag did not move it');
    expect(find.byType(PhotoViewer), findsOneWidget, reason: 'it closed');
    expect(top(t), closeTo(start, 0.5), reason: 'it did not spring back');
    expect(alpha(t), closeTo(1, 0.001));
  });

  testWidgets('a drag under 120 px at 600 px/s (under 700) springs back', (
    t,
  ) async {
    await open(t);
    final dy = await dragTo(t, 100, px: 12);
    expect(dy, lessThanOrEqualTo(120));
    expect(find.byType(PhotoViewer), findsOneWidget, reason: 'it closed');
  });

  testWidgets('a slow drag past 120 px closes it', (t) async {
    await open(t);
    final dy = await dragTo(t, 140);
    expect(dy, greaterThan(120));
    expect(find.byType(PhotoViewer), findsNothing);
    expect(find.text('chat behind'), findsOneWidget);
  });

  testWidgets('a short fling faster than 700 px/s closes it', (t) async {
    await open(t);
    final start = top(t);
    final g = await grab(t);
    for (var i = 0; i < 3; i++) {
      await step(t, g, 20, 10); // 2000 px/s
    }
    expect(top(t) - start, lessThan(120), reason: 'not a short fling');
    await g.up();
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
  });

  testWidgets('while dragged the background fades as 1 - dy/400, down to 0', (
    t,
  ) async {
    await open(t);
    final start = top(t);
    final g = await grab(t);
    await drag(t, g, 100, 10);
    final dy = top(t) - start;
    expect(dy, greaterThan(50));
    expect(alpha(t), closeTo(1 - dy / 400, 0.01));
    await drag(t, g, 400, 10);
    expect(top(t) - start, greaterThan(400));
    expect(alpha(t), closeTo(0, 0.001), reason: 'alpha must clamp at 0');
    await g.up();
    await t.pumpAndSettle();
  });

  testWidgets('pinched in, a vertical drag pans the photo and does not close', (
    t,
  ) async {
    await open(t);
    await pinchIn(t);
    final g = await grab(t);
    await drag(t, g, 200, 10);
    await g.up();
    await t.pumpAndSettle();
    expect(
      find.byType(PhotoViewer),
      findsOneWidget,
      reason: 'zoomed, it closed',
    );
    expect(alpha(t), closeTo(1, 0.001), reason: 'zoomed, the background faded');
  });

  testWidgets('a page change resets the zoom: a swipe down closes again', (
    t,
  ) async {
    await open(t);
    await pinchIn(t);
    final pages = t.widget<PageView>(
      find.descendant(
        of: find.byKey(const ValueKey('viewer-pages')),
        matching: find.byType(PageView),
        matchRoot: true,
      ),
    );
    pages.controller!.jumpToPage(1);
    await t.pumpAndSettle();
    await settleImages(t);
    pages.controller!.jumpToPage(0);
    await t.pumpAndSettle();
    await settleImages(t);
    expect(scale(t), closeTo(1, 0.01), reason: 'the zoom survived the page');
    await dragTo(t, 160);
    expect(find.byType(PhotoViewer), findsNothing);
  });
}
