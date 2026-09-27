// Scrolling the app's own gallery grid (the attachment sheet, and the same
// sheet as the square picture picker) back through the phone's photos, from
// the Gallery.recent contract in lib/features/chat/domain/gallery.dart: the
// grid starts with page 0 and, scrolled to within ~600 px of the bottom,
// asks for the next page, appending in order until a short page ends it; no
// page is asked for twice unless its last request failed; a thin SIS
// progress line shows under the grid exactly while a page loads; a failed
// page raises "Could not load more photos." and keeps what was loaded, and
// scrolling near the bottom again retries it.
//
// Shared by both mounts of the sheet so each runs the very same scenarios.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/features/chat/domain/gallery.dart';

import 'fakes.dart';
import 'sis_ui.dart';

/// The page size the contract names as recent()'s default.
const pageSize = 60;

/// A library of [n] photos, newest first: p0 is the newest.
List<GalleryPhoto> photoLibrary(int n) => [
  for (var i = 0; i < n; i++) GalleryPhoto('p$i'),
];

List<String> ids(Iterable<GalleryPhoto> photos) => [
  for (final p in photos) p.id,
];

/// The pages the grid asked for, in order.
List<int> pagesAsked(GalleryFake g) => [for (final r in g.recentPages) r.page];

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Finder get grid => find.byType(GridView);

ScrollPosition gridPosition(WidgetTester t) => t
    .state<ScrollableState>(
      find.descendant(of: grid, matching: find.byType(Scrollable)).first,
    )
    .position;

/// Jumps the grid so its bottom edge is [fromBottom] px away.
Future<void> jumpToBottom(WidgetTester t, {double fromBottom = 0}) async {
  final p = gridPosition(t);
  p.jumpTo(math.max(0, p.maxScrollExtent - fromBottom));
  await steps(t);
}

/// A member's finger: drags the grid by [dy] (negative = towards older
/// photos) and lets the scroll finish.
Future<void> swipe(WidgetTester t, double dy) async {
  await t.drag(grid, Offset(0, dy));
  await steps(t);
}

/// Scrolls near the bottom the way a member does when it did not load:
/// a little up, then back down to the end.
Future<void> wiggleAtBottom(WidgetTester t) async {
  await swipe(t, 200);
  await swipe(t, -400);
}

/// Flings to the bottom until the grid stops growing (or [max] rounds).
Future<void> scrollToEnd(WidgetTester t, {int max = 20}) async {
  for (var i = 0; i < max; i++) {
    final before = gridPosition(t).maxScrollExtent;
    await swipe(t, -3000);
    await jumpToBottom(t);
    if (gridPosition(t).maxScrollExtent == before &&
        i > 0 &&
        find.byType(SisProgressLine).evaluate().isEmpty) {
      return;
    }
  }
}

/// Every photo tile in the grid, in reading order (row by row, left to
/// right), found by walking the whole grid top to bottom. A photo shown
/// twice appears twice; a photo missing is missing.
Future<List<String>> gridOrder(WidgetTester t) async {
  final p = gridPosition(t);
  final byPlace = <(int, int), String>{};
  final step = p.viewportDimension / 2;
  for (var at = 0.0; ; at += step) {
    p.jumpTo(math.min(at, p.maxScrollExtent));
    await t.pump();
    for (final e
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('sheet-photo-'),
            )
            .evaluate()) {
      final box = e.renderObject! as RenderBox;
      if (!box.hasSize) continue;
      final g = box.localToGlobal(Offset.zero);
      final place = ((g.dy + p.pixels).round(), g.dx.round());
      final id = (e.widget.key! as ValueKey<String>).value.substring(
        'sheet-photo-'.length,
      );
      byPlace[place] = id;
    }
    if (at >= p.maxScrollExtent) break;
  }
  await steps(t); // lets the thumbnails the walk asked for arrive
  final places = byPlace.keys.toList()
    ..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [for (final k in places) byPlace[k]!];
}

/// The sheet is open on page 0 of [g], a library of more than one page.
/// Scrolling far from the bottom asks for nothing; near it, the next page.
Future<void> expectNextPageOnlyNearBottom(WidgetTester t, GalleryFake g) async {
  expect(g.recentPages.map((r) => r.count).toSet(), {
    pageSize,
  }, reason: 'pages of the contract\'s 60 photos');
  expect(pagesAsked(g), [0], reason: 'opening asks for the first page only');
  expect(find.byType(SisProgressLine), findsNothing);

  await jumpToBottom(t, fromBottom: 1200);
  expect(pagesAsked(g), [
    0,
  ], reason: '1200 px from the bottom is not near it: nothing asked yet');

  await jumpToBottom(t, fromBottom: 300);
  expect(pagesAsked(g), [
    0,
    1,
  ], reason: '300 px from the bottom must ask for the next page');
}

/// The sheet is open on [g], holding [n] photos. Scrolled to the end, every
/// page was asked for exactly once, and the grid holds all of them, newest
/// first, no duplicates, no gaps; more scrolling asks for nothing.
Future<void> expectPagesToEnd(WidgetTester t, GalleryFake g, int n) async {
  await scrollToEnd(t);

  final last = n ~/ pageSize; // the first page shorter than pageSize
  expect(pagesAsked(g), [
    for (var i = 0; i <= last; i++) i,
  ], reason: 'every page once, in order, up to the first short one');
  expect(await gridOrder(t), ids(photoLibrary(n)));

  await jumpToBottom(t);
  await wiggleAtBottom(t);
  await swipe(t, -3000);
  expect(pagesAsked(g), [
    for (var i = 0; i <= last; i++) i,
  ], reason: 'a short page ends it: nothing asked past the end');
  expect(find.byType(SisProgressLine), findsNothing);
  expect(notice, findsNothing);
}

/// The sheet is open on page 0 of [g], a library of more than two pages.
/// While page 1 is slow a progress line shows under the grid and no second
/// request goes out, however much the member scrolls.
Future<void> expectSlowPage(WidgetTester t, GalleryFake g) async {
  g.holdRecent();
  await jumpToBottom(t);
  expect(pagesAsked(g), [0, 1]);
  expect(
    find.byType(SisProgressLine),
    findsOneWidget,
    reason: 'a page is loading: the progress line shows',
  );
  final line = t.getRect(find.byType(SisProgressLine));
  final area = t.getRect(grid);
  expect(
    line.center.dy,
    greaterThanOrEqualTo(area.bottom - line.height - 1),
    reason: 'the progress line sits under the grid ($line vs grid $area)',
  );

  await wiggleAtBottom(t);
  await swipe(t, -3000);
  await jumpToBottom(t, fromBottom: 100);
  await jumpToBottom(t);
  expect(pagesAsked(g), [
    0,
    1,
  ], reason: 'page 1 is still loading: scrolling must not ask for it again');
  expect(find.byType(SisProgressLine), findsOneWidget);

  g.releaseRecent();
  await steps(t);
  expect(
    find.byType(SisProgressLine),
    findsNothing,
    reason: 'the page arrived: the progress line goes',
  );
  expect(pagesAsked(g).where((p) => p == 1), hasLength(1));
  await jumpToBottom(t);
  expect(find.byKey(const ValueKey('sheet-photo-p119')), findsOneWidget);
}

/// The sheet is open on page 0 of [g], holding [n] photos (more than one
/// page). Page 1 fails once: a notice, the loaded photos stay, nothing is
/// asked again until the member scrolls near the bottom, then page 1 again.
Future<void> expectFailureAndRetry(WidgetTester t, GalleryFake g, int n) async {
  g.failingPages.add(1);
  await jumpToBottom(t);
  expect(pagesAsked(g), [0, 1]);
  expect(
    noticeSaying('Could not load more photos.'),
    findsOneWidget,
    reason: 'a failed page is reported in the SIS notice',
  );
  expect(find.byType(SnackBar), findsNothing);
  expect(find.byType(SisProgressLine), findsNothing);
  expect(
    find.byKey(const ValueKey('sheet-photo-p59')),
    findsOneWidget,
    reason: 'the photos already loaded stay',
  );
  expect(find.text('No photos yet'), findsNothing);

  await t.pump(const Duration(seconds: 1));
  expect(pagesAsked(g), [
    0,
    1,
  ], reason: 'no retry until the member scrolls again (no request loop)');

  g.failingPages.clear();
  await wiggleAtBottom(t);
  expect(pagesAsked(g), [
    0,
    1,
    1,
  ], reason: 'scrolling near the bottom again retries the page that failed');
  expect(find.byKey(const ValueKey('sheet-photo-p60')), findsOneWidget);

  await drainNotice(t);
  await scrollToEnd(t);
  final last = n ~/ pageSize;
  expect(pagesAsked(g), [0, 1, for (var i = 1; i <= last; i++) i]);
  expect(await gridOrder(t), ids(photoLibrary(n)));
}

// A reload from page 0 -- "Allow more" here -- makes any page load already
// in flight a no-op when it completes: it neither appends its photos, nor
// advances the next page, nor changes the progress line, nor raises "Could
// not load more photos." if it fails. Of two rapid reloads only the newest
// applies. Afterwards the grid pages on normally from the fresh page 0.

/// The library the reload scenarios open on, in limited access.
const reloadLibrary = 200;

/// What the member allowed before "Allow more": all but p5..p9.
final reloadAllowed = [
  for (var i = 0; i < reloadLibrary; i++)
    if (i < 5 || i >= 10) 'p$i',
];

Future<void> tapAllowMore(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('sheet-allow-more')));
}

/// The sheet is open on page 0 of [g]: limited access to [reloadAllowed] of
/// photoLibrary(reloadLibrary). Page 1 is in flight when the member taps
/// "Allow more" and adds p5..p9. The stale page 1 then
/// completes -- after the fresh page 0 arrived ([staleLast]) or before --
/// with photos, or with an error ([fails]); either way it changes nothing.
Future<void> expectStalePageIgnored(
  WidgetTester t,
  GalleryFake g, {
  required bool staleLast,
  bool fails = false,
}) async {
  const stale = 1, fresh = 2; // indexes into g.recentPages
  g.reRequestAdds = {for (var i = 5; i < 10; i++) 'p$i'};
  if (fails) g.failingPages.add(1);
  g.holdRecent();
  await jumpToBottom(t);
  expect(pagesAsked(g), [0, 1]);
  expect(find.byType(SisProgressLine), findsOneWidget);

  await tapAllowMore(t);
  await steps(t);
  expect(pagesAsked(g), [0, 1, 0], reason: '"Allow more" reloads page 0');
  expect(g.heldRecentCalls, [stale, fresh]);

  Future<void> releaseStale() async {
    final line = find.byType(SisProgressLine).evaluate().length;
    final waits = sisWait.evaluate().length;
    g.releaseRecentCall(stale);
    await steps(t);
    expect(
      find.byType(SisProgressLine).evaluate().length,
      line,
      reason: 'the stale page must not change the progress line',
    );
    expect(sisWait.evaluate().length, waits);
    expect(
      notice,
      findsNothing,
      reason: 'a stale page is not the grid\'s: its failure says nothing',
    );
    expect(pagesAsked(g), [0, 1, 0], reason: 'nothing retried or advanced');
  }

  if (!staleLast) await releaseStale();
  g.releaseRecentCall(fresh);
  await steps(t);
  expect(find.byKey(const ValueKey('sheet-photo-p5')), findsOneWidget);
  if (staleLast) await releaseStale();
  expect(
    find.byType(SisProgressLine),
    findsNothing,
    reason: 'nothing of this grid is loading',
  );

  // Still holding: walking the grid to its end asks for the next page but
  // cannot append it, so this is exactly what the grid holds now.
  expect(
    await gridOrder(t),
    ids(photoLibrary(pageSize)),
    reason: 'exactly the fresh page 0: no stale photos, no duplicates',
  );
  expect(pagesAsked(g), [
    0,
    1,
    0,
    1,
  ], reason: 'paging restarts from the fresh page 0: page 1 is next');
  expect(notice, findsNothing);

  g.failingPages.clear();
  g.releaseRecent();
  await steps(t);
  await scrollToEnd(t);
  expect(pagesAsked(g), [0, 1, 0, 1, 2, 3]);
  expect(await gridOrder(t), ids(photoLibrary(reloadLibrary)));
  expect(notice, findsNothing);
}

/// The sheet is open on page 0 of [g]: limited access to all of
/// photoLibrary(reloadLibrary). The member taps "Allow more" twice in quick
/// succession: two reloads of page 0 race. The older one completes
/// ([newestFirst]: after the newer one, else before it) with photos the
/// newer one does not have; only the newer one ever shows.
Future<void> expectNewestReloadWins(
  WidgetTester t,
  GalleryFake g, {
  required bool newestFirst,
}) async {
  const older = 1, newer = 2; // indexes into g.recentPages
  final library = photoLibrary(reloadLibrary);
  // What the older reload finds: a photo the newer one never has.
  final olderLibrary = [const GalleryPhoto('stale'), ...library];
  // What the newer reload finds, and what the grid pages through after.
  final newerLibrary = library.skip(20).toList();
  g.allowed = {'stale', ...ids(library)};
  g.holdRecent();

  // Two taps within one frame: the button is still on screen for both.
  await tapAllowMore(t);
  await tapAllowMore(t);
  await steps(t);
  expect(pagesAsked(g), [
    0,
    0,
    0,
  ], reason: 'two quick taps on "Allow more": two reloads of page 0');
  expect(g.heldRecentCalls, [older, newer]);

  Future<void> releaseOlder() async {
    g.photos = olderLibrary;
    g.releaseRecentCall(older);
    await steps(t);
    expect(
      find.byKey(const ValueKey('sheet-photo-stale')),
      findsNothing,
      reason: 'the older reload was superseded: its page must never show',
    );
  }

  if (!newestFirst) await releaseOlder();
  g.photos = newerLibrary;
  g.releaseRecentCall(newer);
  await steps(t);
  expect(find.byKey(const ValueKey('sheet-photo-p20')), findsOneWidget);
  if (newestFirst) await releaseOlder();
  g.photos = newerLibrary;

  expect(
    await gridOrder(t),
    ids(newerLibrary.take(pageSize)),
    reason: 'the newest reload\'s page 0, and only it',
  );
  expect(pagesAsked(g), [0, 0, 0, 1]);
  expect(find.byType(SisProgressLine), findsOneWidget);

  g.releaseRecent();
  await steps(t);
  await scrollToEnd(t);
  expect(pagesAsked(g), [0, 0, 0, 1, 2, 3]);
  expect(await gridOrder(t), ids(newerLibrary));
  expect(notice, findsNothing);
}
