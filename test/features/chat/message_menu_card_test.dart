// showMenuCard (0.30.9), written from its contract only:
//  * a floating card of rows (`menu-<keyId>`, in the given order) inside the
//    `message-menu` Column, next to a global [anchor] Rect;
//  * above the anchor, below it when there is no room above; always fully on
//    screen minus the safe areas; never over the anchor when there is room;
//  * [alignEnd] lines the card's right edge up with the anchor's;
//  * returns the tapped row's value, null on a tap outside or Back;
//  * on screen after one frame plus a 120 ms fade, no async work;
//  * a destructive row is styled apart from the others.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/presentation/message_menu_card.dart';
import 'package:sis/l10n/app_localizations.dart';

const _screen = Size(400, 800);
const _safeTop = 40.0;
const _safeBottom = 30.0;

final _actions = [
  const MenuCardAction(
    value: 'reply',
    keyId: 'reply',
    icon: Icons.reply,
    label: 'Reply',
  ),
  const MenuCardAction(
    value: 'copy',
    keyId: 'copy',
    icon: Icons.copy,
    label: 'Copy',
  ),
  const MenuCardAction(
    value: 'delete',
    keyId: 'delete',
    icon: Icons.delete,
    label: 'Delete',
    destructive: true,
  ),
];

Finder get card => find.byKey(const ValueKey('message-menu'));
Finder row(String id) => find.byKey(ValueKey('menu-$id'));

/// Hosts a screen of [_screen] with notch/home-bar safe areas and opens the
/// card at [anchor]. The returned list receives the card's result.
Future<List<String?>> open(
  WidgetTester tester,
  Rect anchor, {
  bool alignEnd = false,
  bool settle = true,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = _screen
    ..padding = const FakeViewPadding(top: _safeTop, bottom: _safeBottom)
    ..viewPadding = const FakeViewPadding(top: _safeTop, bottom: _safeBottom);
  addTearDown(tester.view.reset);

  final results = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: sisTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => GestureDetector(
            key: const ValueKey('host'),
            behavior: HitTestBehavior.opaque,
            onTap: () async => results.add(
              await showMenuCard<String>(
                context,
                anchor: anchor,
                actions: _actions,
                alignEnd: alignEnd,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // A spot on the host that is not the anchor.
  await tester.tapAt(
    anchor.top > 400 ? const Offset(200, 100) : const Offset(200, 700),
  );
  if (settle) await tester.pumpAndSettle();
  return results;
}

void expectOnScreen(Rect r) {
  expect(r.left, greaterThanOrEqualTo(0), reason: 'left $r');
  expect(r.right, lessThanOrEqualTo(_screen.width), reason: 'right $r');
  expect(r.top, greaterThanOrEqualTo(_safeTop), reason: 'top $r');
  expect(
    r.bottom,
    lessThanOrEqualTo(_screen.height - _safeBottom),
    reason: 'bottom $r',
  );
}

List<Color?> colorsIn(WidgetTester tester, Finder f) => [
  for (final t in tester.widgetList<RichText>(
    find.descendant(of: f, matching: find.byType(RichText)),
  ))
    t.text.style?.color,
];

void main() {
  testWidgets('rows in the given order, with their labels', (tester) async {
    await open(tester, const Rect.fromLTWH(20, 600, 200, 50));
    expect(card, findsOneWidget);
    final tops = [
      for (final id in ['reply', 'copy', 'delete'])
        tester.getTopLeft(row(id)).dy,
    ];
    expect(tops[0], lessThan(tops[1]));
    expect(tops[1], lessThan(tops[2]));
    for (final (id, label) in [
      ('reply', 'Reply'),
      ('copy', 'Copy'),
      ('delete', 'Delete'),
    ]) {
      expect(
        find.descendant(of: row(id), matching: find.text(label)),
        findsOneWidget,
      );
    }
  });

  testWidgets('a destructive row is styled apart, in the error colour', (
    tester,
  ) async {
    await open(tester, const Rect.fromLTWH(20, 600, 200, 50));
    final error = sisTheme(Brightness.light).colorScheme.error;
    final danger = colorsIn(tester, row('delete'));
    final normal = colorsIn(tester, row('reply'));
    expect(danger, isNotEmpty);
    expect(danger, everyElement(error), reason: 'icon and label');
    expect(normal, everyElement(isNot(error)));
  });

  testWidgets('returns the tapped row\'s value and closes', (tester) async {
    final results = await open(tester, const Rect.fromLTWH(20, 600, 200, 50));
    await tester.tap(row('copy'));
    await tester.pumpAndSettle();
    expect(results, ['copy']);
    expect(card, findsNothing);
  });

  testWidgets('a tap outside closes it with null', (tester) async {
    final results = await open(tester, const Rect.fromLTWH(20, 600, 200, 50));
    final c = tester.getRect(card);
    const spot = Offset(380, 60);
    expect(c.contains(spot), isFalse);
    await tester.tapAt(spot);
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(card, findsNothing);
  });

  testWidgets('Back closes it with null', (tester) async {
    final results = await open(tester, const Rect.fromLTWH(20, 600, 200, 50));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(card, findsNothing);
  });

  testWidgets('fully shown one frame plus 120 ms after the call', (
    tester,
  ) async {
    await open(tester, const Rect.fromLTWH(20, 600, 200, 50), settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(card, findsOneWidget);
    for (final fade in tester.widgetList<FadeTransition>(
      find.ancestor(of: card, matching: find.byType(FadeTransition)),
    )) {
      expect(fade.opacity.value, 1.0);
    }
    for (final scale in tester.widgetList<ScaleTransition>(
      find.ancestor(of: card, matching: find.byType(ScaleTransition)),
    )) {
      expect(scale.scale.value, 1.0);
    }
    expect(row('reply').hitTestable(), findsOneWidget);
  });

  group('layout', () {
    testWidgets('above an anchor low on the screen', (tester) async {
      const anchor = Rect.fromLTWH(20, 600, 200, 50);
      await open(tester, anchor);
      final c = tester.getRect(card);
      expect(c.bottom, lessThanOrEqualTo(anchor.top));
      expectOnScreen(c);
    });

    testWidgets('flips below an anchor near the top', (tester) async {
      const anchor = Rect.fromLTWH(20, 70, 200, 50);
      await open(tester, anchor);
      final c = tester.getRect(card);
      expect(c.top, greaterThanOrEqualTo(anchor.bottom));
      expectOnScreen(c);
    });

    testWidgets('flips below an anchor under the safe area', (tester) async {
      const anchor = Rect.fromLTWH(20, 10, 200, 40);
      await open(tester, anchor);
      final c = tester.getRect(card);
      expect(c.top, greaterThanOrEqualTo(anchor.bottom));
      expectOnScreen(c);
    });

    testWidgets('stays on screen for an anchor at the right edge', (
      tester,
    ) async {
      const anchor = Rect.fromLTWH(360, 600, 40, 50);
      await open(tester, anchor);
      final c = tester.getRect(card);
      expectOnScreen(c);
      expect(c.overlaps(anchor), isFalse);
    });

    testWidgets('stays on screen for an anchor taller than the screen room', (
      tester,
    ) async {
      await open(tester, const Rect.fromLTWH(20, 20, 200, 770));
      expectOnScreen(tester.getRect(card));
    });

    testWidgets('alignEnd lines up the right edges', (tester) async {
      const anchor = Rect.fromLTWH(150, 600, 230, 50);
      await open(tester, anchor, alignEnd: true);
      final c = tester.getRect(card);
      expect(c.right, moreOrLessEquals(anchor.right, epsilon: 1));
      expect(c.bottom, lessThanOrEqualTo(anchor.top));
    });

    testWidgets('without alignEnd the left edges line up', (tester) async {
      const anchor = Rect.fromLTWH(20, 600, 230, 50);
      await open(tester, anchor);
      expect(
        tester.getRect(card).left,
        moreOrLessEquals(anchor.left, epsilon: 1),
      );
    });
  });
}
