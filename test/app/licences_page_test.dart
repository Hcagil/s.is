// The Open-source licences page, written from its contract: every registry
// entry grouped under each package it names, packages alphabetical with a
// count only when a package has several entries, and a detail page that lays
// each paragraph out as the licence text asks — centred headers centred,
// nested clauses indented 16 px per level, one widget per paragraph.
//
// The registry is fed hand-built entries so every paragraph shape is known;
// the real bundled registry is checked in licences_real_registry_test.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/licences_page.dart';
import 'package:sis/app/theme.dart';

class _Entry extends LicenseEntry {
  const _Entry(this.packages, this.paragraphs);

  @override
  final List<String> packages;
  @override
  final List<LicenseParagraph> paragraphs;
}

_Entry _text(List<String> packages, String text) =>
    _Entry(packages, [LicenseParagraph(text, 0)]);

const _header = 'CENTRED HEADER';
const _longCentred =
    'A centred notice long enough to wrap onto a second line, so that the '
    'last line is shorter than the width and shows where the text is aligned '
    'rather than where its box happens to sit on the page.';
const _plain = 'Plain clause at the margin';
const _one = 'Clause nested one level';
const _two = 'Clause nested two levels';

/// Mounts the page over exactly [entries] and waits for the list to load.
Future<void> _mount(WidgetTester t, List<LicenseEntry> entries) async {
  LicenseRegistry.reset();
  addTearDown(LicenseRegistry.reset);
  LicenseRegistry.addLicense(() => Stream.fromIterable(entries));
  // Tall enough that the list builds every tile, whatever each tile's height.
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(800, 2400);
  addTearDown(t.view.reset);
  final first = entries.first.packages.first;
  await t.pumpWidget(
    MaterialApp(
      theme: sisTheme(Brightness.light),
      home: const SisLicencesPage(
        applicationName: 'SIS',
        applicationVersion: '1.0.0',
      ),
    ),
  );
  for (var i = 0; i < 50 && find.text(first).evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump();
  }
  await t.pumpAndSettle();
  expect(find.text(first), findsOneWidget, reason: 'the list never loaded');
}

Future<void> _open(WidgetTester t, String package) async {
  await t.tap(find.text(package));
  await t.pumpAndSettle();
}

RenderParagraph _paragraph(WidgetTester t, String text) => t.renderObject(
  find.descendant(
    of: find.text(text),
    matching: find.byType(RichText),
    matchRoot: true,
  ),
);

/// Global x of the left edge of the first glyph of [text].
double _glyphLeft(WidgetTester t, String text) {
  final p = _paragraph(t, text);
  final caret = p.getOffsetForCaret(const TextPosition(offset: 0), Rect.zero);
  return p.localToGlobal(caret).dx;
}

/// Global horizontal midpoint of the drawn glyphs on [text]'s last line.
double _lastLineMid(WidgetTester t, String text) {
  final p = _paragraph(t, text);
  final boxes = p.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  final last = boxes.last.toRect();
  return p.localToGlobal(last.center).dx;
}

/// Tile subtitles of the form "N licences" (or a stray "1 licence").
final _counts = find.textContaining(RegExp(r'^\d+ licences?$'));

void main() {
  group('detail page lays out each paragraph as the licence asks', () {
    Future<void> openLayout(WidgetTester t) async {
      await _mount(t, [
        const _Entry(
          ['alpha'],
          [
            LicenseParagraph(_header, LicenseParagraph.centeredIndent),
            LicenseParagraph(_plain, 0),
            LicenseParagraph(_one, 1),
            LicenseParagraph(_two, 2),
            LicenseParagraph(_longCentred, LicenseParagraph.centeredIndent),
          ],
        ),
      ]);
      await _open(t, 'alpha');
    }

    testWidgets('every paragraph is its own widget, in order, spaced', (
      t,
    ) async {
      await openLayout(t);
      final order = [_header, _plain, _one, _two, _longCentred];
      for (final text in order) {
        expect(
          find.text(text),
          findsOneWidget,
          reason: 'merged or lost: $text',
        );
      }
      for (var i = 1; i < order.length; i++) {
        final above = t.getRect(find.text(order[i - 1]));
        final below = t.getRect(find.text(order[i]));
        expect(
          below.top,
          greaterThan(above.bottom),
          reason: '"${order[i]}" must sit below "${order[i - 1]}" with space',
        );
      }
    });

    testWidgets('a centred paragraph is drawn centred on the page', (t) async {
      await openLayout(t);
      final mid = t.view.physicalSize.width / t.view.devicePixelRatio / 2;
      expect(_lastLineMid(t, _header), moreOrLessEquals(mid, epsilon: 1));
      // Wrapped: the short last line shows the alignment, not the box.
      expect(_lastLineMid(t, _longCentred), moreOrLessEquals(mid, epsilon: 4));
      final header = t.widget<Text>(find.text(_header));
      expect(header.textAlign, TextAlign.center);
      expect(
        find.ancestor(of: find.text(_header), matching: find.byType(Center)),
        findsWidgets,
      );
    });

    testWidgets('indented paragraphs start 16 px further in per level', (
      t,
    ) async {
      await openLayout(t);
      final margin = _glyphLeft(t, _plain);
      expect(_glyphLeft(t, _one) - margin, moreOrLessEquals(16, epsilon: .5));
      expect(_glyphLeft(t, _two) - margin, moreOrLessEquals(32, epsilon: .5));
      expect(
        _glyphLeft(t, _header),
        greaterThan(margin + 32),
        reason: 'a centred header is not a margin paragraph',
      );
    });
  });

  group('package list', () {
    final registry = <LicenseEntry>[
      _text(['zeta'], 'zeta licence'),
      _text(['beta'], 'beta first licence'),
      _text(['gamma', 'delta'], 'shared by gamma and delta'),
      _text(['alpha'], 'alpha licence'),
      _text(['beta'], 'beta second licence'),
      _text(['eta'], 'eta one'),
      _text(['eta'], 'eta two'),
      _text(['eta'], 'eta three'),
      _text(['mu'], 'mu licence'),
    ];
    const sorted = ['alpha', 'beta', 'delta', 'eta', 'gamma', 'mu', 'zeta'];

    testWidgets('one tile per package, alphabetical', (t) async {
      await _mount(t, registry);
      for (final p in sorted) {
        expect(find.text(p), findsOneWidget, reason: p);
      }
      for (var i = 1; i < sorted.length; i++) {
        expect(
          t.getTopLeft(find.text(sorted[i])).dy,
          greaterThan(t.getTopLeft(find.text(sorted[i - 1])).dy),
          reason: '${sorted[i]} must come after ${sorted[i - 1]}',
        );
      }
    });

    testWidgets('a count shows only under packages with several entries', (
      t,
    ) async {
      await _mount(t, registry);
      expect(_counts, findsNWidgets(2), reason: 'only beta and eta have many');
      for (final (package, count) in [('beta', 2), ('eta', 3)]) {
        final label = find.text('$count licences');
        expect(label, findsOneWidget);
        final next = sorted[sorted.indexOf(package) + 1];
        final y = t.getTopLeft(label).dy;
        expect(y, greaterThan(t.getTopLeft(find.text(package)).dy));
        expect(y, lessThan(t.getTopLeft(find.text(next)).dy), reason: package);
      }
    });

    testWidgets('a package with two entries shows both texts once each', (
      t,
    ) async {
      await _mount(t, registry);
      await _open(t, 'beta');
      expect(find.text('beta first licence'), findsOneWidget);
      expect(find.text('beta second licence'), findsOneWidget);
      expect(find.text('alpha licence'), findsNothing);
    });

    testWidgets('an entry naming two packages appears under each', (t) async {
      await _mount(t, registry);
      for (final p in ['gamma', 'delta']) {
        await _open(t, p);
        expect(find.text('shared by gamma and delta'), findsOneWidget);
        t.state<NavigatorState>(find.byType(Navigator)).pop();
        await t.pumpAndSettle();
      }
    });
  });
}
