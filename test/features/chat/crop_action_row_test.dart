// The crop screen's bottom bar, written from its contract only:
//
//  - Cancel on the left, rotate (crop-free-rotate) at the bar's exact centre,
//    Reset between rotate and Done, Done on the right.
//  - Not changed: Reset has opacity 0 and ignores pointers.
//  - Reset touches neither rotate nor Done and sits centred between them;
//    gaps >= 16 dp at ~392 dp, >= 8 dp at 360 dp, >= 0 at 320 dp.
//  - No overflow at 320 dp in Turkish with text scale 1.3.
//  - Reset, Cancel and rotate tap targets are each >= 48 dp.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/presentation/crop_dock.dart';
import 'package:sis/l10n/app_localizations.dart';

Finder key(String k) => find.byKey(ValueKey(k));

class Taps {
  int cancel = 0, done = 0, rotate = 0, reset = 0;
}

Future<Taps> pumpBar(
  WidgetTester t, {
  required double width,
  required bool changed,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  t.view.physicalSize = Size(width * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final taps = Taps();
  await t.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: sisTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          final l = AppLocalizations.of(context);
          return Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CropActionRow(
                cancelLabel: l.cropCancel,
                doneLabel: l.cropDone,
                resetLabel: l.cropReset,
                rotateLabel: l.cropRotateLabel,
                changed: changed,
                canDone: true,
                onCancel: () => taps.cancel++,
                onDone: () => taps.done++,
                onRotate: () => taps.rotate++,
                onReset: () => taps.reset++,
              ),
            ),
          );
        },
      ),
    ),
  );
  await t.pumpAndSettle();
  return taps;
}

/// Product of every opacity above and below the finder's element.
double opacity(WidgetTester t, Finder f) {
  final el = f.evaluate().single;
  var o = 1.0;
  void take(RenderObject? ro) {
    if (ro is RenderOpacity) o *= ro.opacity;
    if (ro is RenderAnimatedOpacity) o *= ro.opacity.value;
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

Rect rect(WidgetTester t, String k) => t.getRect(key('crop-free-$k'));

void main() {
  for (final changed in [true, false]) {
    for (final width in [392.0, 360.0, 320.0]) {
      testWidgets('rotate sits at the bar centre (changed=$changed, '
          '${width.toInt()} dp)', (t) async {
        await pumpBar(t, width: width, changed: changed);
        final bar = t.getRect(find.byType(CropActionRow));
        expect(bar.width, closeTo(width, 0.01), reason: 'bar spans the view');
        expect(rect(t, 'rotate').center.dx, closeTo(bar.center.dx, 0.5));
        expect(rect(t, 'cancel').center.dx, lessThan(bar.center.dx));
        expect(rect(t, 'done').center.dx, greaterThan(bar.center.dx));
      });
    }
  }

  testWidgets('not changed: Reset is invisible and ignores taps', (t) async {
    final taps = await pumpBar(t, width: 392, changed: false);
    expect(opacity(t, key('crop-free-reset')), 0);
    expect(key('crop-free-reset').hitTestable(), findsNothing);
    await t.tapAt(rect(t, 'reset').center);
    await t.pump();
    expect(taps.reset, 0);
  });

  testWidgets('changed: Reset is visible and its tap reaches onReset', (
    t,
  ) async {
    final taps = await pumpBar(t, width: 392, changed: true);
    expect(opacity(t, key('crop-free-reset')), 1);
    await t.tap(key('crop-free-reset'));
    await t.pump();
    expect(taps.reset, 1);
    expect(taps.rotate + taps.done + taps.cancel, 0);
  });

  final minGap = {392.0: 16.0, 360.0: 8.0, 320.0: 0.0};
  for (final MapEntry(key: width, value: gap) in minGap.entries) {
    for (final locale in const [Locale('en'), Locale('tr')]) {
      testWidgets('${width.toInt()} dp ${locale.languageCode}: Reset clears '
          'rotate and Done by >= $gap dp, centred between them', (t) async {
        await pumpBar(t, width: width, changed: true, locale: locale);
        final reset = rect(t, 'reset');
        final rotate = rect(t, 'rotate');
        final done = rect(t, 'done');
        expect(reset.overlaps(rotate), isFalse, reason: '$reset vs $rotate');
        expect(reset.overlaps(done), isFalse, reason: '$reset vs $done');
        final left = reset.left - rotate.right;
        final right = done.left - reset.right;
        expect(left, greaterThanOrEqualTo(gap), reason: 'Reset-rotate gap');
        expect(right, greaterThanOrEqualTo(gap), reason: 'Reset-Done gap');
        expect(
          reset.center.dx,
          closeTo((rotate.right + done.left) / 2, 0.5),
          reason: 'centred between rotate and Done',
        );
      });
    }
  }

  testWidgets('320 dp, Turkish, text scale 1.3: no overflow, nothing touches', (
    t,
  ) async {
    await pumpBar(
      t,
      width: 320,
      changed: true,
      locale: const Locale('tr'),
      textScale: 1.3,
    );
    expect(t.takeException(), isNull);
    expect(find.text('Sıfırla'), findsOneWidget);
    final bar = t.getRect(find.byType(CropActionRow));
    for (final k in ['cancel', 'rotate', 'reset', 'done']) {
      final r = rect(t, k);
      expect(r.left, greaterThanOrEqualTo(bar.left - 0.01), reason: k);
      expect(r.right, lessThanOrEqualTo(bar.right + 0.01), reason: k);
    }
    expect(rect(t, 'reset').overlaps(rect(t, 'rotate')), isFalse);
    expect(rect(t, 'reset').overlaps(rect(t, 'done')), isFalse);
  });

  for (final (width, lang, scale) in const [
    (392.0, 'en', 1.0),
    (392.0, 'tr', 1.3),
    (320.0, 'tr', 1.3),
  ]) {
    testWidgets('${width.toInt()} dp $lang x$scale: Reset, Cancel and rotate '
        'tap targets are >= 48 dp', (t) async {
      final taps = await pumpBar(
        t,
        width: width,
        changed: true,
        locale: Locale(lang),
        textScale: scale,
      );
      for (final k in ['reset', 'cancel', 'rotate']) {
        final r = rect(t, k);
        expect(r.width, greaterThanOrEqualTo(48), reason: '$k width');
        expect(r.height, greaterThanOrEqualTo(48), reason: '$k height');
        // The whole 48x48 square around the centre must reach the button.
        for (final d in const [
          Offset(-23, -23),
          Offset(23, -23),
          Offset(-23, 23),
          Offset(23, 23),
        ]) {
          await t.tapAt(r.center + d);
          await t.pump();
        }
      }
      expect(taps.reset, 4);
      expect(taps.cancel, 4);
      expect(taps.rotate, 4);
      expect(taps.done, 0);
    });
  }
}
