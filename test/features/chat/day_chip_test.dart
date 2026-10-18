// withDayChips and DayChip, from the contract only: the message list's item
// builder (reversed list, index 0 = newest; index timeline.length = the
// "loading older" row) gets one day chip above the first message of every
// local day, the very first message included; none between same-day
// messages and none on the loading row; 8 px above and below the chip.
// Run under TZ=JST-9 like every unit test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/domain/timeline.dart';
import 'package:sis/features/chat/presentation/day_chip.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/chat_launcher.dart';

const rowHeight = 40.0;

/// Oldest first, as a timeline is.
List<TimelineEntry> timelineOf(List<(String, DateTime)> rows) => [
  for (final (id, at) in rows)
    MessageEntry(chatMessage(id, body: id, createdAt: at)),
];

Finder row(String id) => find.byKey(ValueKey('row-$id'));
final loader = find.byKey(const ValueKey('older-loading'));
final chips = find.byType(DayChip);

Future<void> pumpList(
  WidgetTester t,
  List<TimelineEntry> timeline, {
  bool loadingOlder = false,
}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: sisTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ListView.builder(
          reverse: true,
          itemCount: timeline.length + (loadingOlder ? 1 : 0),
          itemBuilder: withDayChips(timeline, (context, i) {
            if (i == timeline.length) {
              return const SizedBox(
                key: ValueKey('older-loading'),
                height: rowHeight,
              );
            }
            final e = timeline[timeline.length - 1 - i] as MessageEntry;
            return SizedBox(
              key: ValueKey('row-${e.message.id}'),
              height: rowHeight,
              child: Text(e.message.id),
            );
          }),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// The day each chip on screen stands for, top of the screen first.
List<DateTime> chipDays(WidgetTester t) {
  final found = [
    for (final e in chips.evaluate())
      (e.widget as DayChip, t.getTopLeft(find.byWidget(e.widget)).dy),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [
    for (final (c, _) in found)
      DateTime(c.at.toLocal().year, c.at.toLocal().month, c.at.toLocal().day),
  ];
}

/// The chip directly above [id]: the one whose bottom is closest above the
/// row's top, within 40 px; null when none.
Finder? chipAbove(WidgetTester t, String id) {
  final top = t.getRect(row(id)).top;
  for (final e in chips.evaluate()) {
    final f = find.byWidget(e.widget);
    final r = t.getRect(f);
    if (r.bottom <= top + 0.5 && top - r.bottom < 40) return f;
  }
  return null;
}

void main() {
  final today = DateTime.now();
  DateTime on(DateTime day, int h, int m) =>
      DateTime(day.year, day.month, day.day, h, m);
  // Fixed past days (another year): their labels never depend on "today".
  final d1 = DateTime(2024, 3, 4);
  final d2 = DateTime(2024, 3, 5);

  testWidgets('one chip per local day, above the first message of the day, '
      'the very first message included', (t) async {
    final tl = timelineOf([
      ('a1', on(d1, 9, 0)),
      ('a2', on(d1, 9, 5)),
      ('a3', on(d1, 23, 59)),
      ('b1', on(d2, 0, 1)),
      ('b2', on(d2, 12, 0)),
      ('c1', on(today, 0, 0)),
      ('c2', on(today, 0, 0)),
    ]);
    await pumpList(t, tl);

    expect(chips, findsNWidgets(3), reason: 'three local days, three chips');
    expect(chipDays(t), [d1, d2, DateTime(today.year, today.month, today.day)]);
    for (final first in ['a1', 'b1', 'c1']) {
      expect(chipAbove(t, first), isNotNull, reason: 'chip above $first');
    }
    for (final sameDay in ['a2', 'a3', 'b2', 'c2']) {
      expect(chipAbove(t, sameDay), isNull, reason: 'no chip above $sameDay');
    }
    expect(find.text('March 4, 2024'), findsOneWidget);
    expect(find.text('March 5, 2024'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('23:59 and 00:01 of the next local day are two days', (t) async {
    await pumpList(t, timelineOf([('x', on(d1, 23, 59)), ('y', on(d2, 0, 1))]));
    expect(chipAbove(t, 'x'), isNotNull);
    expect(chipAbove(t, 'y'), isNotNull, reason: 'midnight starts a day');
  });

  testWidgets('UTC message times are split by the local day', (t) async {
    // 14:59Z and 15:01Z: one UTC day, but 23:59 and 00:01 under JST-9.
    final a = DateTime.utc(2024, 3, 4, 14, 59);
    final b = DateTime.utc(2024, 3, 4, 15, 1);
    final split = a.toLocal().day != b.toLocal().day;
    await pumpList(t, timelineOf([('x', a), ('y', b)]));
    expect(chips, findsNWidgets(split ? 2 : 1));
    expect(chipAbove(t, 'x'), isNotNull);
    expect(chipAbove(t, 'y'), split ? isNotNull : isNull);
  });

  testWidgets('a chat of one day has one chip, above its first message', (
    t,
  ) async {
    await pumpList(
      t,
      timelineOf([('m1', on(today, 0, 0)), ('m2', on(today, 0, 1))]),
    );
    expect(chips, findsOneWidget);
    expect(chipAbove(t, 'm1'), isNotNull);
  });

  testWidgets('no chip on the "loading older" row', (t) async {
    await pumpList(
      t,
      timelineOf([('a1', on(d1, 9, 0)), ('b1', on(d2, 9, 0))]),
      loadingOlder: true,
    );
    expect(loader, findsOneWidget, reason: 'fixture: the loader shows');
    expect(
      find.descendant(of: loader, matching: chips),
      findsNothing,
      reason: 'the loader row holds no chip',
    );
    expect(chips, findsNWidgets(2), reason: 'only the two day starts');
    final loaderRect = t.getRect(loader);
    for (final e in chips.evaluate()) {
      final r = t.getRect(find.byWidget(e.widget));
      expect(
        r.overlaps(loaderRect),
        isFalse,
        reason: 'no chip drawn over the loader',
      );
    }
    expect(
      t.getRect(loader).bottom,
      lessThanOrEqualTo(t.getRect(chipAbove(t, 'a1')!).top),
      reason: 'the loader sits above the oldest chip, not inside the list',
    );
  });

  testWidgets('8 px between the chip and the rows above and below it', (
    t,
  ) async {
    await pumpList(t, timelineOf([('a1', on(d1, 9, 0)), ('b1', on(d2, 9, 0))]));
    final chip = chipAbove(t, 'b1')!;
    // The painted chip: the outermost decorated box around its text.
    final text = t.getRect(
      find.descendant(of: chip, matching: find.byType(Text)),
    );
    final pill = find
        .descendant(
          of: chip,
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox ||
                w is Material ||
                w is PhysicalModel ||
                w is PhysicalShape,
          ),
        )
        .evaluate()
        .map((e) => t.getRect(find.byWidget(e.widget)))
        .where((r) => r.contains(text.center))
        .toList();
    expect(pill, isNotEmpty, reason: 'fixture: the chip paints a box');
    final box = pill.first;
    expect(box.top - t.getRect(row('a1')).bottom, moreOrLessEquals(8));
    expect(t.getRect(row('b1')).top - box.bottom, moreOrLessEquals(8));
  });

  testWidgets('DayChip shows dayChipLabel against its own now', (t) async {
    final now = DateTime(2026, 10, 18, 12);
    await t.pumpWidget(
      MaterialApp(
        theme: sisTheme(Brightness.light),
        locale: const Locale('tr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              DayChip(at: DateTime(2026, 10, 18, 1), now: now),
              DayChip(at: DateTime(2026, 10, 16, 1), now: now),
              DayChip(at: DateTime(2025, 10, 16, 1), now: now),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Bugün'), findsOneWidget);
    expect(find.text('16 Ekim'), findsOneWidget);
    expect(find.text('16 Ekim 2025'), findsOneWidget);
  });
}
