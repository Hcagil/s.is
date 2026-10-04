// The picture crop screen, written from its contract (docs/DECISIONS.md,
// 2026-09-28 "Pictures like WhatsApp"): the photo under a 320x320 square
// frame (crop-frame), moved and zoomed with the fingers in an
// InteractiveViewer (crop-viewer). The photo always covers the square -- zoom
// in only, never an empty edge -- and the first framing is the centre. "Use"
// (crop-use, disabled while the photo decodes or a crop is running) hands the
// framed square to the PictureCropper as fractions 0..1 of the source's width
// and height and resolves with what it returns; a null crop says "That photo
// could not be used." and keeps the screen open; back resolves null.
//
// The geometry is checked through the fractions the cropper receives: a fake
// cannot hide them. Sources are real, decodable images of known size.
import 'dart:ui' show SemanticsFlags, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/presentation/crop_screen.dart';

import '../../support/chat_launcher.dart'
    show osBack, platforms, screenHeight, screenWidth, stroke;
import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

const couldNotUse = 'That photo could not be used.';

Finder byKey(String key) => find.byKey(ValueKey(key));

PickedImage source(int width, int height) => PickedImage(
  bytes: pngOf(width, height),
  contentType: 'image/jpeg',
  extension: 'jpg',
);

/// A screen that opens the crop screen on [src] and keeps what it resolves.
class Host {
  Host(this.src);
  final PickedImage src;
  final cropper = PictureCropperFake();
  PickedImage? result;
  bool resolved = false;

  Widget app() => ProviderScope(
    overrides: [pictureCropperProvider.overrideWithValue(cropper)],
    child: MaterialApp(
      theme: sisTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await openCropScreen(context, src);
                resolved = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

SemanticsFlags _flags(WidgetTester t, Finder f) =>
    t.getSemantics(f).getSemanticsData().flagsCollection;

bool useEnabled(WidgetTester t) =>
    _flags(t, byKey('crop-use')).isEnabled == Tristate.isTrue;

/// Pumps the fake clock only: real decoding cannot finish here.
Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Lets the photo decode (in the engine, outside the fake clock) until Use
/// is offered.
Future<void> untilReady(WidgetTester t) async {
  for (var i = 0; i < 100; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
    if (byKey('crop-use').evaluate().isNotEmpty && useEnabled(t)) {
      await t.pumpAndSettle();
      return;
    }
  }
  fail('Use never became available: the photo did not decode');
}

/// Opens the crop screen on a [width]x[height] photo and waits until it is
/// ready to use.
Future<Host> open(WidgetTester t, int width, int height) async {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  final h = Host(source(width, height));
  await t.pumpWidget(h.app());
  await t.tap(byKey('open'));
  await steps(t);
  expect(find.byType(CropScreen), findsOneWidget);
  await untilReady(t);
  return h;
}

/// Taps Use and lets the crop finish.
Future<void> use(WidgetTester t) async {
  await t.tap(byKey('crop-use'));
  await steps(t);
}

/// One finger dragging the photo by [by], in small steps and slowly, so the
/// viewer takes it as a pan with no fling after it.
Future<void> pan(WidgetTester t, Offset by) async {
  final centre = t.getCenter(byKey('crop-frame'));
  final g = await t.startGesture(centre);
  const n = 20;
  for (var i = 1; i <= n; i++) {
    await g.moveTo(centre + by * (i / n), timeStamp: Duration(seconds: i));
    await t.pump(const Duration(milliseconds: 20));
  }
  await g.up(timeStamp: const Duration(seconds: n + 5));
  await t.pumpAndSettle();
}

/// Two fingers on either side of the frame's centre spreading from
/// [fromGap] to [toGap] apart: a pinch whose focal point stays at the
/// centre, zooming by toGap / fromGap.
Future<void> pinch(WidgetTester t, double fromGap, double toGap) async {
  final c = t.getCenter(byKey('crop-frame'));
  final a = await t.startGesture(c - Offset(fromGap / 2, 0), pointer: 1);
  final b = await t.startGesture(c + Offset(fromGap / 2, 0), pointer: 2);
  const n = 20;
  for (var i = 1; i <= n; i++) {
    final gap = fromGap + (toGap - fromGap) * i / n;
    await a.moveTo(c - Offset(gap / 2, 0), timeStamp: Duration(seconds: i));
    await b.moveTo(c + Offset(gap / 2, 0), timeStamp: Duration(seconds: i));
    await t.pump(const Duration(milliseconds: 20));
  }
  await a.up(timeStamp: const Duration(seconds: n + 5));
  await b.up(timeStamp: const Duration(seconds: n + 5));
  await t.pumpAndSettle();
}

/// The rectangle the cropper was last asked for.
CropCall lastCall(Host h) {
  expect(h.cropper.calls, isNotEmpty, reason: 'Use never asked for a crop');
  return h.cropper.calls.last;
}

/// [c] lies inside the photo -- every fraction within 0..1, with room --
/// and is a square in the source's pixels.
void expectSquareInside(CropCall c, int width, int height, String when) {
  for (final (name, v) in [
    ('left', c.left),
    ('top', c.top),
    ('right', c.right),
    ('bottom', c.bottom),
  ]) {
    expect(v, inInclusiveRange(-1e-9, 1 + 1e-9), reason: '$when: $name $v');
  }
  expect(c.right, greaterThan(c.left), reason: '$when: empty width');
  expect(c.bottom, greaterThan(c.top), reason: '$when: empty height');
  expect(
    (c.right - c.left) * width,
    closeTo((c.bottom - c.top) * height, 0.01 * width),
    reason: '$when: not a square in the photo\'s pixels',
  );
}

void expectRect(
  CropCall c, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  double tolerance = 0.005,
  required String when,
}) {
  expect(c.left, closeTo(left, tolerance), reason: '$when: left');
  expect(c.top, closeTo(top, tolerance), reason: '$when: top');
  expect(c.right, closeTo(right, tolerance), reason: '$when: right');
  expect(c.bottom, closeTo(bottom, tolerance), reason: '$when: bottom');
}

void main() {
  group('the screen', () {
    testWidgets('a 320x320 frame; Use is disabled until the photo has '
        'decoded, and tapping it early asks for nothing', (t) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final h = Host(source(2000, 1000));
      await t.pumpWidget(h.app());
      await t.tap(byKey('open'));
      await steps(t);

      // Decoding runs outside the fake clock: it cannot have finished yet.
      expect(byKey('crop-use'), findsOneWidget);
      expect(useEnabled(t), isFalse, reason: 'Use offered before decoding');
      await t.tap(byKey('crop-use'), warnIfMissed: false);
      await steps(t);
      expect(h.cropper.calls, isEmpty);
      expect(h.resolved, isFalse);

      await untilReady(t);
      expect(t.getSize(byKey('crop-frame')), const Size(320, 320));
      expect(byKey('crop-viewer'), findsOneWidget);
      expect(
        t.widget(byKey('crop-viewer')),
        isA<InteractiveViewer>(),
        reason: 'crop-viewer is the InteractiveViewer',
      );
    });

    testWidgets('Use resolves with exactly what the cropper made, from the '
        'source\'s own bytes, as a 640 px square', (t) async {
      final h = await open(t, 2000, 1000);
      await use(t);

      final call = lastCall(h);
      expect(h.cropper.calls, hasLength(1));
      expect(call.source, h.src.bytes, reason: 'not the source that was shown');
      expect(call.size, 640);
      expect(h.resolved, isTrue, reason: 'Use did not close the screen');
      await steps(t, 30);
      expect(find.byType(CropScreen), findsNothing);
      expect(h.result?.bytes, h.cropper.output);
      expect(h.result?.contentType, 'image/jpeg');
      expect(h.result?.extension, 'jpg');
    });

    testWidgets('while the crop runs, Use is disabled and a second tap '
        'asks for nothing more', (t) async {
      final h = await open(t, 2000, 1000);
      h.cropper.hold();
      await use(t);
      expect(h.cropper.calls, hasLength(1));
      expect(useEnabled(t), isFalse, reason: 'Use offered while busy');
      await t.tap(byKey('crop-use'), warnIfMissed: false);
      await steps(t);
      expect(h.cropper.calls, hasLength(1), reason: 'a second crop was asked');
      expect(h.resolved, isFalse);

      h.cropper.release();
      await steps(t);
      expect(h.resolved, isTrue);
      expect(h.result?.bytes, h.cropper.output);
    });

    testWidgets('a crop that fails says "$couldNotUse", keeps the screen '
        'open, and Use works again', (t) async {
      final h = await open(t, 2000, 1000);
      h.cropper.fails = true;
      await use(t);

      expect(h.cropper.calls, hasLength(1));
      final shown = t.widgetList<SisNotice>(notice).toList();
      expect(shown, hasLength(1), reason: 'the failure is not reported');
      expect(shown.single.message, couldNotUse);
      expect(shown.single.isError, isTrue);
      expect(find.byType(CropScreen), findsOneWidget, reason: 'screen closed');
      expect(h.resolved, isFalse);
      expect(useEnabled(t), isTrue, reason: 'Use not offered again');

      h.cropper.fails = false;
      await use(t);
      expect(h.resolved, isTrue);
      expect(h.result?.bytes, h.cropper.output);
      await drainNotice(t);
    });

    testWidgets('back resolves null: no crop, no notice', (t) async {
      final h = await open(t, 2000, 1000);
      await pan(t, const Offset(-100, 0));
      await t.pageBack();
      await steps(t);

      expect(h.resolved, isTrue);
      expect(h.result, isNull);
      expect(h.cropper.calls, isEmpty);
      expect(notice, findsNothing);
      await steps(t, 30);
      expect(find.byType(CropScreen), findsNothing);
    });
  });

  group('the framed square, as fractions of the photo', () {
    testWidgets('first framing: the centre of a landscape photo', (t) async {
      final h = await open(t, 2000, 1000);
      await use(t);
      expectRect(
        lastCall(h),
        left: 0.25,
        top: 0,
        right: 0.75,
        bottom: 1,
        when: 'first framing, 2000x1000',
      );
      expectSquareInside(lastCall(h), 2000, 1000, 'first framing');
    });

    testWidgets('first framing: the centre of a portrait photo', (t) async {
      final h = await open(t, 1000, 2000);
      await use(t);
      expectRect(
        lastCall(h),
        left: 0,
        top: 0.25,
        right: 1,
        bottom: 0.75,
        when: 'first framing, 1000x2000',
      );
    });

    testWidgets('first framing: all of a square photo', (t) async {
      final h = await open(t, 800, 800);
      await use(t);
      expectRect(
        lastCall(h),
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
        when: 'first framing, 800x800',
      );
    });

    testWidgets('moved to the right edge and far past it: stops at the '
        'edge, never beyond 1', (t) async {
      final h = await open(t, 2000, 1000);
      // The photo is 640 wide on screen; 160 px of it lie right of the frame.
      await pan(t, const Offset(-1000, 0));
      await pan(t, const Offset(-1000, 0));
      await use(t);
      expectSquareInside(lastCall(h), 2000, 1000, 'past the right edge');
      expectRect(
        lastCall(h),
        left: 0.5,
        top: 0,
        right: 1,
        bottom: 1,
        when: 'past the right edge',
      );
    });

    testWidgets('moved to the left edge and far past it: stops at the '
        'edge, never below 0', (t) async {
      final h = await open(t, 2000, 1000);
      await pan(t, const Offset(1000, 0));
      await pan(t, const Offset(1000, 300));
      await use(t);
      expectSquareInside(lastCall(h), 2000, 1000, 'past the left edge');
      expectRect(
        lastCall(h),
        left: 0,
        top: 0,
        right: 0.5,
        bottom: 1,
        when: 'past the left edge',
      );
    });

    testWidgets('moved part way: the square follows the finger', (t) async {
      final h = await open(t, 2000, 1000);
      // 64 screen px of a 640 px wide photo is a tenth of its width.
      await pan(t, const Offset(-64, 0));
      await use(t);
      expectRect(
        lastCall(h),
        left: 0.35,
        top: 0,
        right: 0.85,
        bottom: 1,
        tolerance: 0.02,
        when: 'moved 64 px left',
      );
      expectSquareInside(lastCall(h), 2000, 1000, 'moved part way');
    });

    testWidgets('moved up and down on a landscape photo: nothing to move '
        'into, the full height stays', (t) async {
      final h = await open(t, 2000, 1000);
      await pan(t, const Offset(0, -600));
      await pan(t, const Offset(0, 1200));
      await use(t);
      expectRect(
        lastCall(h),
        left: 0.25,
        top: 0,
        right: 0.75,
        bottom: 1,
        when: 'moved vertically',
      );
    });

    testWidgets('zoomed in twice about the centre: half the square, still '
        'centred', (t) async {
      final h = await open(t, 2000, 1000);
      await pinch(t, 80, 160);
      await use(t);
      expectSquareInside(lastCall(h), 2000, 1000, 'zoomed in');
      expectRect(
        lastCall(h),
        left: 0.375,
        top: 0.25,
        right: 0.625,
        bottom: 0.75,
        tolerance: 0.02,
        when: 'zoomed in x2',
      );
    });

    testWidgets('zoomed in, then moved into a corner and past it: a smaller '
        'square, still inside the photo', (t) async {
      final h = await open(t, 2000, 1000);
      await pinch(t, 80, 160);
      await pan(t, const Offset(2000, 2000));
      await use(t);
      final c = lastCall(h);
      expectSquareInside(c, 2000, 1000, 'zoomed, top-left corner');
      expect(c.right - c.left, lessThan(0.5 - 0.05), reason: 'not smaller');
      expectRect(
        c,
        left: 0,
        top: 0,
        right: 0.25,
        bottom: 0.5,
        tolerance: 0.02,
        when: 'zoomed x2, top-left corner',
      );
    });

    testWidgets('zooming out never shows an empty edge: the square stays '
        'the full height', (t) async {
      final h = await open(t, 2000, 1000);
      await pinch(t, 200, 40);
      await pan(t, const Offset(300, 300));
      await use(t);
      final c = lastCall(h);
      expectSquareInside(c, 2000, 1000, 'zoomed out');
      expect(c.top, closeTo(0, 0.005));
      expect(c.bottom, closeTo(1, 0.005));
      expect(c.right - c.left, closeTo(0.5, 0.005));
    });
  });

  // 0.30.13: the crop screen opts out of swipe-back -- a right drag moves
  // the photo -- while back still leaves.
  group('swipe-back opt-out', () {
    testWidgets('a right drag pans the photo and stays', (t) async {
      final h = await open(t, 2000, 1000);
      await pan(t, const Offset(64, 0));
      expect(find.byType(CropScreen), findsOneWidget, reason: 'it left');
      expect(h.resolved, isFalse);
      await use(t);
      expectRect(
        lastCall(h),
        left: 0.15,
        top: 0,
        right: 0.65,
        bottom: 1,
        tolerance: 0.02,
        when: 'moved 64 px right',
      );
    }, variant: platforms);

    testWidgets('a long right drag from mid-screen stays', (t) async {
      final h = await open(t, 2000, 1000);
      await stroke(
        t,
        Offset(screenWidth(t) * 0.45, screenHeight(t) * 0.4),
        Offset(screenWidth(t) * 0.6, 0),
        over: const Duration(milliseconds: 1500),
      );
      await t.pumpAndSettle();
      expect(find.byType(CropScreen), findsOneWidget, reason: 'it left');
      expect(h.resolved, isFalse);
    }, variant: platforms);

    testWidgets('OS back through the platform channel leaves, null', (t) async {
      final h = await open(t, 2000, 1000);
      await osBack(t);
      expect(find.byType(CropScreen), findsNothing);
      expect(h.resolved, isTrue);
      expect(h.result, isNull);
    }, variant: platforms);
  });
}
