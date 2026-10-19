// The free crop screen, written from its contract only:
//
//  - openFreeCropScreen(context, source) -> PickedImage?; the renderer comes
//    from photoCropRendererProvider.
//  - Starts as the whole photo, chip 0 (Free), Reset hidden (opacity 0,
//    ignores taps). Chips: 1 Original, 2 Square, 3..8 = 3:2 5:3 4:3 5:4 7:5
//    16:9, inverted when the turned photo is portrait; a chip fits the
//    largest centred frame of that ratio. With a ratio only corners resize,
//    keeping it. Min side 32 dp; drags clamp to the photo.
//  - Rotate: one turn anticlockwise, the frame turns with the photo, the
//    ratio inverts, Reset appears. Reset: whole photo, Free, no turn.
//  - Cancel / back: null. Done: renderer.render(source, turns, fractions of
//    the turned photo); its result is returned; null shows cropUnusable and
//    stays. Done is disabled while busy or before the decode.
//  - Undecodable source: photoOpenFailed shows; Cancel still works.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/presentation/crop_painters.dart';
import 'package:sis/features/chat/presentation/free_crop_screen.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/chat_launcher.dart' show osBack, phoneView;
import '../../support/crop_fakes.dart';

Finder key(String k) => find.byKey(ValueKey(k));

late PickedImage wide; // 200x100
late PickedImage cutResult;

class Host {
  Host(this.source, this.renderer);
  final PickedImage source;
  final RendererFake renderer;
  PickedImage? result;
  bool resolved = false;

  Widget app() => ProviderScope(
    overrides: [photoCropRendererProvider.overrideWithValue(renderer)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: sisTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await openFreeCropScreen(context, source);
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

/// Lets the real image decode finish (it runs outside fake time).
Future<void> decoded(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
  await t.pumpAndSettle();
}

Future<Host> open(
  WidgetTester t, {
  PickedImage? source,
  RendererFake? renderer,
  bool decode = true,
}) async {
  phoneView(t);
  final h = Host(source ?? wide, renderer ?? RendererFake(answer: cutResult));
  await t.pumpWidget(h.app());
  await t.tap(key('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 16));
  if (decode) await decoded(t);
  return h;
}

Rect photo(WidgetTester t) => t.getRect(key('crop-free-photo'));

/// The frame on screen: the painter's frame is in the painter's own space.
Rect frame(WidgetTester t) {
  final paint = t.widget<CustomPaint>(key('crop-free-frame'));
  return (paint.painter! as CropFramePainter).frame.shift(
    t.getTopLeft(key('crop-free-frame')),
  );
}

final chipRow = find
    .ancestor(
      of: find.byWidgetPredicate((w) => '${w.key}'.contains("'crop-chip-")),
      matching: find.byType(Scrollable),
    )
    .first;

/// Chips sit in a row that scrolls; bring chip [i] fully into view.
Future<void> reveal(WidgetTester t, int i) async {
  for (var n = 0; n < 40; n++) {
    final k = key('crop-chip-$i');
    if (k.evaluate().isNotEmpty) {
      final r = t.getRect(k);
      final row = t.getRect(chipRow);
      if (r.left >= row.left && r.right <= row.right) return;
    }
    final built = find
        .byWidgetPredicate((w) => '${w.key}'.contains("'crop-chip-"))
        .evaluate()
        .map((e) => int.parse('${e.widget.key}'.replaceAll(RegExp(r'\D'), '')))
        .toList();
    final ahead = k.evaluate().isNotEmpty
        ? t.getRect(k).right > t.getRect(chipRow).right
        : built.every((b) => b < i);
    await t.drag(chipRow, Offset(ahead ? -60 : 60, 0));
    await t.pumpAndSettle();
  }
  fail('chip $i never came into view');
}

Future<void> chip(WidgetTester t, int i) async {
  await reveal(t, i);
  await tapKey(t, 'crop-chip-$i');
}

/// The label of chip [i] (scrolled into view).
Future<Finder> chipText(WidgetTester t, int i, String text) async {
  await reveal(t, i);
  return find.descendant(of: key('crop-chip-$i'), matching: find.text(text));
}

/// The frame as fractions of the photo on screen.
Rect fractions(WidgetTester t) {
  final p = photo(t), f = frame(t);
  return Rect.fromLTRB(
    (f.left - p.left) / p.width,
    (f.top - p.top) / p.height,
    (f.right - p.left) / p.width,
    (f.bottom - p.top) / p.height,
  );
}

Future<void> drag(WidgetTester t, Offset from, Offset by) async {
  final g = await t.startGesture(from);
  await t.pump(const Duration(milliseconds: 20));
  for (var i = 0; i < 10; i++) {
    await g.moveBy(by / 10);
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await t.pumpAndSettle();
}

/// Just inside a corner of the frame, so it grabs that corner.
Offset inside(Offset corner, Rect f) =>
    corner +
    Offset(
      corner.dx < f.center.dx ? 10 : -10,
      corner.dy < f.center.dy ? 10 : -10,
    );

Future<void> tapKey(WidgetTester t, String k) async {
  await t.tap(key(k));
  await t.pumpAndSettle();
}

/// Effective opacity of [f]: every opacity above it and inside it.
double opacity(WidgetTester t, Finder f) {
  final el = f.evaluate().single;
  var o = 1.0;
  void take(RenderObject? ro) {
    if (ro is RenderOpacity) o *= ro.opacity;
    if (ro is RenderAnimatedOpacity) o *= ro.opacity.value;
    if (ro is RenderSliverOpacity) o *= ro.opacity;
  }

  RenderObject? ro = el.renderObject;
  while (ro != null) {
    take(ro);
    ro = ro.parent;
  }
  void down(Element e) => e.visitChildren((c) {
    if (c is RenderObjectElement) take(c.renderObject);
    down(c);
  });
  down(el);
  return o;
}

void expectFrac(Cut c, Rect r, {double tol = 0.01}) {
  expect(c.left, closeTo(r.left, tol), reason: 'left');
  expect(c.top, closeTo(r.top, tol), reason: 'top');
  expect(c.right, closeTo(r.right, tol), reason: 'right');
  expect(c.bottom, closeTo(r.bottom, tol), reason: 'bottom');
}

void expectRect(Rect a, Rect b, {double tol = 0.01}) {
  expect(a.left, closeTo(b.left, tol), reason: 'left of $a vs $b');
  expect(a.top, closeTo(b.top, tol), reason: 'top of $a vs $b');
  expect(a.right, closeTo(b.right, tol), reason: 'right of $a vs $b');
  expect(a.bottom, closeTo(b.bottom, tol), reason: 'bottom of $a vs $b');
}

Future<Cut> done(WidgetTester t, Host h) async {
  await t.tap(key('crop-free-done'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 60));
  await t.pumpAndSettle();
  return h.renderer.cuts.last;
}

const full = Rect.fromLTRB(0, 0, 1, 1);

void main() {
  setUpAll(() async {
    wide = PickedImage(
      bytes: await png(200, 100),
      contentType: 'image/png',
      extension: 'png',
      photoGroup: 'album1',
    );
    cutResult = PickedImage(
      bytes: await png(10, 10),
      contentType: 'image/png',
      extension: 'png',
    );
  });

  testWidgets('starts as the whole photo, Free chip, Reset hidden and '
      'untappable; Done untouched cuts the whole photo, no turn', (t) async {
    final h = await open(t);
    for (final k in [
      'crop-free-area',
      'crop-free-photo',
      'crop-free-frame',
      'crop-free-rotate',
      'crop-free-reset',
      'crop-free-cancel',
      'crop-free-done',
      for (var i = 0; i <= 2; i++) 'crop-chip-$i',
    ]) {
      expect(key(k), findsOneWidget, reason: k);
    }
    expect(photo(t).width / photo(t).height, closeTo(2, 0.02));
    expectRect(fractions(t), full);
    expect(opacity(t, key('crop-free-reset')), 0);
    expect(key('crop-free-reset').hitTestable(), findsNothing);

    final c = await done(t, h);
    expect(h.renderer.cuts, hasLength(1));
    expect(c.source, same(wide));
    expect(c.turns, 0);
    expectFrac(c, full);
    expect(h.resolved, isTrue);
    expect(h.result, same(cutResult));
    expect(key('crop-free-done'), findsNothing, reason: 'screen not closed');
  });

  testWidgets('chips fit the largest centred frame of their ratio', (t) async {
    final h = await open(t);
    await chip(t, 2); // Square on 200x100
    expectRect(fractions(t), const Rect.fromLTRB(.25, 0, .75, 1));
    await chip(t, 3); // 3:2 -> 150x100
    expectRect(fractions(t), const Rect.fromLTRB(.125, 0, .875, 1));
    await chip(t, 8); // 16:9 -> 177.8x100
    expectRect(fractions(t), const Rect.fromLTRB(.0556, 0, .9444, 1));
    await chip(t, 1); // Original -> whole photo
    expectRect(fractions(t), full);
    await chip(t, 6); // 5:4 -> 125x100
    expectRect(fractions(t), const Rect.fromLTRB(.1875, 0, .8125, 1));
    expect(
      opacity(t, key('crop-free-reset')),
      1,
      reason: 'a ratio is a change',
    );
    final c = await done(t, h);
    expectFrac(c, const Rect.fromLTRB(.1875, 0, .8125, 1));
  });

  testWidgets('rotate: one turn anticlockwise, chip labels invert, a chip '
      'fits the turned (portrait) photo, Reset shows', (t) async {
    final h = await open(t);
    expect(await chipText(t, 3, '3:2'), findsOneWidget);
    await tapKey(t, 'crop-free-rotate');
    expect(
      photo(t).height / photo(t).width,
      closeTo(2, 0.02),
      reason: 'turned',
    );
    expect(
      await chipText(t, 3, '2:3'),
      findsOneWidget,
      reason: 'label not inverted on a portrait photo',
    );
    expect(await chipText(t, 8, '9:16'), findsOneWidget);
    expect(opacity(t, key('crop-free-reset')), 1);
    expect(key('crop-free-reset').hitTestable(), findsOneWidget);

    await chip(t, 3); // 2:3 in 100x200 -> 100x150
    expectRect(fractions(t), const Rect.fromLTRB(0, .125, 1, .875));
    final c = await done(t, h);
    expect(c.turns, 1);
    expectFrac(c, const Rect.fromLTRB(0, .125, 1, .875));
  });

  testWidgets('rotate with a ratio set: the frame turns with the photo and '
      'the ratio inverts', (t) async {
    final h = await open(t);
    await chip(t, 3); // 3:2 -> .125..875 x 0..1
    await tapKey(t, 'crop-free-rotate');
    // Anticlockwise: (x, y) -> (y, 1 - x).
    expectRect(fractions(t), const Rect.fromLTRB(0, .125, 1, .875));
    final f = frame(t);
    expect(f.height / f.width, closeTo(1.5, 0.02), reason: 'now 2:3');
    final c = await done(t, h);
    expect(c.turns, 1);
    expectFrac(c, const Rect.fromLTRB(0, .125, 1, .875));
  });

  testWidgets('after a rotate, a corner drag keeps the inverted ratio', (
    t,
  ) async {
    await open(t);
    await chip(t, 3); // 3:2
    await tapKey(t, 'crop-free-rotate'); // now 2:3
    final f0 = frame(t);
    await drag(
      t,
      inside(f0.bottomRight, f0),
      Offset(-f0.width * .3, -f0.height * .3),
    );
    final f1 = frame(t);
    expect(f1.width, lessThan(f0.width - 5), reason: 'corner did not resize');
    expect(f1.height / f1.width, closeTo(1.5, 0.03), reason: 'ratio not 2:3');
  });

  testWidgets('Free: a corner drag moves that corner; Done sends the turned '
      'fractions after a rotate (anticlockwise, not clockwise)', (t) async {
    final h = await open(t);
    final f0 = frame(t);
    final p = photo(t);
    await drag(t, inside(f0.topLeft, f0), Offset(p.width * .2, p.height * .3));
    final a = fractions(t);
    expect(a.left, closeTo(.2, 0.02));
    expect(a.top, closeTo(.3, 0.02));
    expect(a.right, closeTo(1, 0.01));
    expect(a.bottom, closeTo(1, 0.01));

    await tapKey(t, 'crop-free-rotate');
    // Anticlockwise maps fractions (x, y) to (y, 1 - x).
    final want = Rect.fromLTRB(a.top, 1 - a.right, a.bottom, 1 - a.left);
    expectRect(fractions(t), want, tol: 0.02);
    final c = await done(t, h);
    expect(c.turns, 1);
    expectFrac(c, want, tol: 0.02);
  });

  testWidgets('Free: an edge drag moves that edge', (t) async {
    await open(t);
    final f0 = frame(t);
    await drag(
      t,
      Offset(f0.right - 10, f0.center.dy),
      Offset(-f0.width * .25, 0),
    );
    final a = fractions(t);
    expect(a.right, closeTo(.75, 0.02));
    expect(a.left, closeTo(0, 0.01));
    expect(a.top, closeTo(0, 0.01));
    expect(a.bottom, closeTo(1, 0.01));
  });

  testWidgets('with a ratio, edges are ignored and a corner keeps the ratio', (
    t,
  ) async {
    await open(t);
    await chip(t, 2); // square
    final f0 = frame(t);
    await drag(
      t,
      Offset(f0.right - 10, f0.center.dy),
      Offset(-f0.width * .3, 0),
    );
    expectRect(frame(t), f0, tol: 0.5);

    await drag(
      t,
      inside(f0.bottomRight, f0),
      Offset(-f0.width * .3, -f0.height * .1),
    );
    final f1 = frame(t);
    expect(f1.width, lessThan(f0.width - 5), reason: 'corner did not resize');
    expect(f1.width / f1.height, closeTo(1, 0.02), reason: 'ratio lost');
  });

  testWidgets('tapping Free after a ratio lets edges move again', (t) async {
    await open(t);
    await chip(t, 2);
    await chip(t, 0);
    final f0 = frame(t);
    await drag(
      t,
      Offset(f0.right - 10, f0.center.dy),
      Offset(-f0.width * .2, 0),
    );
    expect(frame(t).right, closeTo(f0.right - f0.width * .2, 1));
  });

  testWidgets('a side never goes under 32 dp; a drag stays inside the photo', (
    t,
  ) async {
    await open(t);
    final f0 = frame(t);
    await drag(t, inside(f0.topLeft, f0), Offset(f0.width * 2, f0.height * 2));
    final f1 = frame(t);
    expect(f1.width, greaterThanOrEqualTo(31.5));
    expect(f1.height, greaterThanOrEqualTo(31.5));
    expect(f1.width, lessThan(40), reason: 'stopped at the minimum');

    await drag(t, inside(f1.topLeft, f1), const Offset(-2000, -2000));
    final p = photo(t);
    final f2 = frame(t);
    expect(f2.left, greaterThanOrEqualTo(p.left - 0.5));
    expect(f2.top, greaterThanOrEqualTo(p.top - 0.5));
    expect(f2.right, lessThanOrEqualTo(p.right + 0.5));
    expect(f2.bottom, lessThanOrEqualTo(p.bottom + 0.5));
    expectRect(fractions(t), full, tol: 0.01);
  });

  testWidgets('Reset: whole photo, Free, no turn; it hides again', (t) async {
    final h = await open(t);
    await chip(t, 2);
    await tapKey(t, 'crop-free-rotate');
    final f0 = frame(t);
    await drag(t, inside(f0.topLeft, f0), Offset(f0.width * .2, f0.width * .2));
    await tapKey(t, 'crop-free-reset');

    expect(
      photo(t).width / photo(t).height,
      closeTo(2, 0.02),
      reason: 'turn not undone',
    );
    expectRect(fractions(t), full);
    expect(opacity(t, key('crop-free-reset')), 0);
    expect(key('crop-free-reset').hitTestable(), findsNothing);
    // Free again: an edge drag moves the edge.
    final f1 = frame(t);
    await drag(
      t,
      Offset(f1.right - 10, f1.center.dy),
      Offset(-f1.width * .25, 0),
    );
    expect(
      fractions(t).right,
      closeTo(.75, 0.02),
      reason: 'not Free after Reset',
    );

    final right = fractions(t).right;
    final c = await done(t, h);
    expect(c.turns, 0);
    expectFrac(c, Rect.fromLTRB(0, 0, right, 1), tol: 0.01);
  });

  testWidgets('Cancel pops null without cutting or asking', (t) async {
    final h = await open(t);
    await chip(t, 2);
    await tapKey(t, 'crop-free-cancel');
    expect(h.resolved, isTrue);
    expect(h.result, isNull);
    expect(h.renderer.cuts, isEmpty);
    expect(key('crop-free-area'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('system back pops null without asking', (t) async {
    final h = await open(t);
    await tapKey(t, 'crop-free-rotate');
    await osBack(t);
    await t.pumpAndSettle();
    expect(h.resolved, isTrue);
    expect(h.result, isNull);
    expect(h.renderer.cuts, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('renderer null: cropUnusable shows, the screen stays, nothing '
      'returned; a second Done can still try', (t) async {
    final h = await open(t, renderer: RendererFake());
    await t.tap(key('crop-free-done'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('That photo could not be used.'), findsOneWidget);
    await t.pumpAndSettle();
    expect(h.resolved, isFalse);
    expect(key('crop-free-done'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();

    h.renderer.answer = cutResult;
    await done(t, h);
    expect(h.renderer.cuts, hasLength(2));
    expect(h.result, same(cutResult));
  });

  testWidgets('Done is disabled while the cut runs', (t) async {
    final r = RendererFake(answer: cutResult)..gate = Completer<void>();
    final h = await open(t, renderer: r);
    await t.tap(key('crop-free-done'));
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(key('crop-free-done'), warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 100));
    expect(r.cuts, hasLength(1), reason: 'a second cut while busy');
    r.gate!.complete();
    await t.pumpAndSettle();
    expect(h.result, same(cutResult));
    expect(r.cuts, hasLength(1));
  });

  testWidgets('Done does nothing before the photo is decoded', (t) async {
    final h = await open(t, decode: false);
    await t.tap(key('crop-free-done'), warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 50));
    expect(h.renderer.cuts, isEmpty);
    expect(h.resolved, isFalse);
    await decoded(t);
  });

  testWidgets('an undecodable photo shows photoOpenFailed; Done cuts '
      'nothing; Cancel closes with null', (t) async {
    final bad = PickedImage(
      bytes: Uint8List.fromList(List<int>.generate(64, (i) => i * 3)),
      contentType: 'image/png',
      extension: 'png',
    );
    final h = await open(t, source: bad);
    expect(find.text('That photo could not be opened.'), findsOneWidget);
    await t.tap(key('crop-free-done'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(h.renderer.cuts, isEmpty);
    await tapKey(t, 'crop-free-cancel');
    expect(h.resolved, isTrue);
    expect(h.result, isNull);
  });
}
