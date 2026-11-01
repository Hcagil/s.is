// Photo viewer zoom (owner 2026-11-01), from the contract:
//
// 1. double-tap at fit zooms to 2.5x about the tapped point, over ~200 ms;
// 2. double-tap while zoomed returns to fit;
// 3. two pointers down (a pinch starting) lock the page swipe and the
//    swipe-down-to-close;
// 4. zoomed, a sideways drag pans the photo; the page does not change;
// 5. swipe-down-to-close is off while zoomed or pinching;
// 6. at fit, a sideways swipe changes page and a swipe down closes;
// 7. changing page resets the zoom to fit;
// 8. starting a pinch stops a running double-tap animation.
// Keys: viewer-pages, viewer-image-$path. The zoom is read from the
// InteractiveViewer's TransformationController around the shown photo.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';

const a = 'c1/a.png';
const b = 'c1/b.png';

Finder inViewer(Finder f) =>
    find.descendant(of: find.byType(PhotoViewer), matching: f);
Finder image(String path) =>
    inViewer(find.byKey(ValueKey('viewer-image-$path')));
Finder viewerOf(String path) => find
    .ancestor(of: image(path), matching: find.byType(InteractiveViewer))
    .first;

Future<void> open(WidgetTester t) async {
  final chat = ChatFake()
    ..store(a, photoPng)
    ..store(b, photoPng);
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
  expect(image(a), findsOneWidget);
}

Matrix4 matrix(WidgetTester t, [String path = a]) =>
    t.widget<InteractiveViewer>(viewerOf(path)).transformationController!.value;
double scale(WidgetTester t, [String path = a]) =>
    matrix(t, path).getMaxScaleOnAxis();
double tx(WidgetTester t) => matrix(t).getTranslation().x;

PageController pages(WidgetTester t) => t
    .widget<PageView>(
      find.descendant(
        of: find.byKey(const ValueKey('viewer-pages')),
        matching: find.byType(PageView),
        matchRoot: true,
      ),
    )
    .controller!;
double page(WidgetTester t) => pages(t).page!;

double alpha(WidgetTester t) => t
    .widget<Scaffold>(inViewer(find.byType(Scaffold)).first)
    .backgroundColor!
    .a;

/// Two taps 80 ms apart; returns once the second finger is up (no pump
/// after it, so the caller times the animation from here).
Future<void> doubleTapAt(WidgetTester t, Offset at) async {
  await t.tapAt(at);
  await t.pump(const Duration(milliseconds: 80));
  await t.tapAt(at);
}

Future<void> zoomIn(WidgetTester t) async {
  await doubleTapAt(t, t.getCenter(image(a)));
  await t.pumpAndSettle();
  expect(scale(t), closeTo(2.5, 0.01), reason: 'double-tap did not zoom');
}

/// One finger moved by [by] in [n] steps of 16 ms, then lifted.
Future<void> drag(WidgetTester t, Offset by, {int n = 20}) async {
  final g = await t.startGesture(t.getCenter(image(a)));
  for (var i = 0; i < n; i++) {
    await g.moveBy(by / n.toDouble());
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await t.pumpAndSettle();
}

/// Two fingers 80 px apart, put down and pumped (a pinch starting).
Future<(TestGesture, TestGesture)> twoDown(WidgetTester t) async {
  final c = t.getCenter(image(a));
  final g1 = await t.startGesture(c - const Offset(40, 0), pointer: 7);
  final g2 = await t.startGesture(c + const Offset(40, 0), pointer: 8);
  await t.pump();
  return (g1, g2);
}

void main() {
  testWidgets('1. double-tap at fit zooms to 2.5x about the tapped point, '
      'animated over about 200 ms', (t) async {
    await open(t);
    expect(scale(t), closeTo(1, 0.001));
    final at = t.getCenter(image(a)) + const Offset(60, 40);
    final local = at - t.getTopLeft(viewerOf(a));
    await doubleTapAt(t, at);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final mid = scale(t);
    expect(mid, greaterThan(1.05), reason: 'not moving at 100 ms');
    expect(mid, lessThan(2.45), reason: 'not animated: done by 100 ms');
    await t.pump(const Duration(milliseconds: 150));
    expect(scale(t), closeTo(2.5, 0.01), reason: 'not at 2.5x by 250 ms');
    final kept = MatrixUtils.transformPoint(matrix(t), local);
    expect(kept.dx, closeTo(local.dx, 1), reason: 'not about the tap (x)');
    expect(kept.dy, closeTo(local.dy, 1), reason: 'not about the tap (y)');
    await t.pumpAndSettle();
    expect(scale(t), closeTo(2.5, 0.01));
  });

  testWidgets('2. double-tap while zoomed (double-tap) returns to fit', (
    t,
  ) async {
    await open(t);
    await zoomIn(t);
    await doubleTapAt(t, t.getCenter(image(a)));
    await t.pumpAndSettle();
    expect(scale(t), closeTo(1, 0.01));
    expect(matrix(t).getTranslation().length, closeTo(0, 0.5));
  });

  testWidgets('2b. double-tap while zoomed (pinch) returns to fit', (t) async {
    await open(t);
    final (g1, g2) = await twoDown(t);
    for (var i = 0; i < 10; i++) {
      await g1.moveBy(const Offset(-10, 0));
      await g2.moveBy(const Offset(10, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    expect(scale(t), greaterThan(1.01), reason: 'the pinch did not zoom');
    await doubleTapAt(t, t.getCenter(image(a)));
    await t.pumpAndSettle();
    expect(scale(t), closeTo(1, 0.01));
  });

  testWidgets('3. two fingers down, a sideways move does not change page', (
    t,
  ) async {
    await open(t);
    final (g1, g2) = await twoDown(t);
    for (var i = 0; i < 20; i++) {
      await g1.moveBy(const Offset(-20, 0));
      await g2.moveBy(const Offset(-20, 0));
      await t.pump(const Duration(milliseconds: 16));
      expect(page(t), 0, reason: 'the page moved under two fingers');
    }
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    expect(page(t), 0);
    expect(find.byType(PhotoViewer), findsOneWidget);
  });

  testWidgets('3/5. two fingers down, a downward move does not close', (
    t,
  ) async {
    await open(t);
    final (g1, g2) = await twoDown(t);
    for (var i = 0; i < 20; i++) {
      await g1.moveBy(const Offset(0, 12));
      await g2.moveBy(const Offset(0, 12));
      await t.pump(const Duration(milliseconds: 16));
      expect(alpha(t), closeTo(1, 0.001), reason: 'faded while pinching');
    }
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget, reason: 'it closed');
  });

  testWidgets('4. zoomed, a sideways drag pans the photo, not the page', (
    t,
  ) async {
    await open(t);
    await zoomIn(t);
    final before = tx(t);
    await drag(t, const Offset(-150, 0));
    expect(page(t), 0, reason: 'zoomed, the page changed');
    expect(tx(t) - before, lessThan(-100), reason: 'the photo did not pan');
    expect(scale(t), closeTo(2.5, 0.01));
  });

  testWidgets('5. zoomed (double-tap), a swipe down does not close', (t) async {
    await open(t);
    await zoomIn(t);
    final g = await t.startGesture(t.getCenter(image(a)));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(0, 12));
      await t.pump(const Duration(milliseconds: 16));
      expect(alpha(t), closeTo(1, 0.001), reason: 'zoomed, it faded');
    }
    await g.up();
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget, reason: 'zoomed, closed');
  });

  testWidgets('6. at fit, a sideways swipe changes page', (t) async {
    await open(t);
    await t.fling(image(a), const Offset(-400, 0), 2000);
    await t.pumpAndSettle();
    expect(page(t), 1);
  });

  testWidgets('6. zoomed in and back out by double-tap, a swipe down closes', (
    t,
  ) async {
    await open(t);
    await zoomIn(t);
    await doubleTapAt(t, t.getCenter(image(a)));
    await t.pumpAndSettle();
    await drag(t, const Offset(0, 300));
    expect(find.byType(PhotoViewer), findsNothing);
  });

  testWidgets('7. a page change resets a double-tap zoom to fit', (t) async {
    await open(t);
    await zoomIn(t);
    pages(t).jumpToPage(1);
    await t.pumpAndSettle();
    await settleImages(t);
    expect(scale(t, b), closeTo(1, 0.01));
    pages(t).jumpToPage(0);
    await t.pumpAndSettle();
    await settleImages(t);
    expect(scale(t), closeTo(1, 0.01), reason: 'the zoom survived the page');
    await drag(t, const Offset(0, 300));
    expect(find.byType(PhotoViewer), findsNothing, reason: 'still zoomed');
  });

  testWidgets('8. a pinch starting stops a running double-tap animation', (
    t,
  ) async {
    await open(t);
    await doubleTapAt(t, t.getCenter(image(a)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    final (g1, g2) = await twoDown(t);
    final held = scale(t);
    expect(held, greaterThan(1.01), reason: 'the animation had not started');
    expect(held, lessThan(2.4), reason: 'the animation had already ended');
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(scale(t), closeTo(held, 0.02), reason: 'the animation ran on');
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    expect(scale(t), lessThan(2.4), reason: 'the animation resumed');
  });

  testWidgets('8b. a pinch that moves stops a running double-tap animation', (
    t,
  ) async {
    await open(t);
    await doubleTapAt(t, t.getCenter(image(a)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    final (g1, g2) = await twoDown(t);
    for (var i = 0; i < 5; i++) {
      await g1.moveBy(const Offset(-10, 0));
      await g2.moveBy(const Offset(10, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    // The pinch itself zooms past 2.5x here; what matters is that once the
    // fingers hold still, nothing moves the photo any more.
    final held = scale(t);
    expect(held, greaterThan(2.6), reason: 'the pinch did not take over');
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(scale(t), closeTo(held, 0.02), reason: 'the animation ran on');
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
  });
}
