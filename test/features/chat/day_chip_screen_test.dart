// Message dates on the real chat screen, from the contract only, mounted as
// production opens a chat (chat_launcher), fakes only at the repositories:
//  * a day chip above the first message of each local day, none same-day;
//  * bubbles keep showing the clock time only (HH:mm);
//  * the readers card shows seenTime ("yesterday at 14:32", "04.03.24 at ...");
//  * every message row keeps its own key: no duplicate-key error with chips,
//    and a bubble keeps its element (its state) when a new message arrives.
// Run under TZ=JST-9 like every unit test.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/day_chip.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';

String two(int v) => v.toString().padLeft(2, '0');
String hm(DateTime at) =>
    '${two(at.toLocal().hour)}:${two(at.toLocal().minute)}';

final oldDay = DateTime(2024, 3, 4, 10, 0);

const longName = Member(
  userId: 'u4',
  displayName: 'Bartholomew Alexander Montgomery-Featherstonehaugh',
);

ChatFake world(List<Message> messages, {List<ReadMark> marks = const []}) =>
    ChatFake(self: me.userId)
      ..history['c1'] = messages
      ..roster['c1'] = [me, bob, cem, longName]
      ..membersResult = const Ok([bob, cem, longName])
      ..readMarksData['c1'] = marks
      ..conversationsResult = const Ok([Conversation(id: 'c1', title: 'Bob')]);

Future<void> open(WidgetTester t, ChatFake chat) async {
  await pumpLauncher(
    t,
    (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
    chat: chat,
  );
  await t.pumpAndSettle();
  expect(find.byType(MessageScreen), findsOneWidget, reason: 'never opened');
}

/// Every text on screen under [of], RichText included, as plain strings.
List<String> textsIn(WidgetTester t, Finder of) => [
  for (final e
      in find.descendant(of: of, matching: find.byType(RichText)).evaluate())
    (e.widget as RichText).text.toPlainText(),
];

/// The painted box of a chip (its DecoratedBox) and of a bubble (the first
/// DecoratedBox under `message-<id>`), in global coordinates.
Rect painted(WidgetTester t, Finder f) {
  final box =
      find
              .descendant(of: f, matching: find.byType(DecoratedBox))
              .evaluate()
              .first
              .renderObject!
          as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

Finder chipOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(DayChip));

/// Opens m1 (mine) and its readers card.
Future<Finder> openReaders(WidgetTester t, List<ReadMark> marks) async {
  await open(
    t,
    world([
      chatMessage('m1', body: 'mine', from: me.userId, createdAt: oldDay),
    ], marks: marks),
  );
  await t.tap(find.byKey(const ValueKey('body-m1')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const ValueKey('seen-by-m1')));
  await t.pumpAndSettle();
  final card = find.byKey(const ValueKey('readers-card'));
  expect(card, findsOneWidget, reason: 'fixture: the card opened');
  return card;
}

void drained(String description, WidgetTesterCallback body) =>
    testWidgets(description, (t) async {
      await body(t);
      await t.pump(const Duration(milliseconds: 50));
    });

void main() {
  final now = DateTime.now();
  final todayAt = DateTime(now.year, now.month, now.day);

  drained('a chip above the first message of each day; bubbles show HH:mm '
      'only; no duplicate-key error', (t) async {
    await open(
      t,
      world([
        chatMessage('o1', body: 'old one', createdAt: oldDay),
        chatMessage(
          'o2',
          body: 'old two',
          createdAt: oldDay.add(const Duration(minutes: 7)),
        ),
        chatMessage('n1', body: 'new one', createdAt: todayAt),
      ]),
    );
    expect(t.takeException(), isNull, reason: 'no duplicate key, no error');
    expect(find.byType(DayChip), findsNWidgets(2));
    expect(find.text('March 4, 2024'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);

    final chipOld = t.getRect(find.text('March 4, 2024'));
    final chipToday = t.getRect(find.text('Today'));
    expect(chipOld.bottom, lessThan(t.getRect(bubble('o1')).top));
    expect(chipToday.bottom, lessThan(t.getRect(bubble('n1')).top));
    expect(
      chipToday.top,
      greaterThan(t.getRect(bubble('o2')).bottom),
      reason: 'the Today chip sits between the days',
    );
    // Nothing between o1 and o2 (same day).
    expect(
      t.getRect(bubble('o2')).top - t.getRect(bubble('o1')).bottom,
      lessThan(chipOld.height),
      reason: 'no chip between same-day messages',
    );

    for (final (id, at) in [
      ('o1', oldDay),
      ('o2', oldDay.add(const Duration(minutes: 7))),
      ('n1', todayAt),
    ]) {
      final texts = textsIn(t, bubble(id));
      expect(
        texts,
        contains(hm(at)),
        reason: 'bubble $id shows ${hm(at)} as its own text: $texts',
      );
      expect(texts.where((s) => s.contains(hm(at))), [
        hm(at),
      ], reason: 'the time text is HH:mm and nothing else: $texts');
      expect(
        texts.any(
          (s) =>
              RegExp(r'\d{1,2}[./-]\d{1,2}').hasMatch(s) ||
              s.contains('2024') ||
              s.contains('Mar') ||
              s.contains('Today') ||
              s.contains('yesterday'),
        ),
        isFalse,
        reason: 'bubble $id shows the time only: $texts',
      );
    }
  });

  drained('8 px from each painted chip to the painted bubble above and '
      'below it', (t) async {
    await open(
      t,
      world([
        chatMessage('o1', body: 'old one', createdAt: oldDay),
        chatMessage('n1', body: 'new one', createdAt: todayAt),
      ]),
    );
    final old = painted(t, chipOf('March 4, 2024'));
    final today = painted(t, chipOf('Today'));
    final o1 = painted(t, bubble('o1'));
    final n1 = painted(t, bubble('n1'));
    expect(o1.top - old.bottom, moreOrLessEquals(8, epsilon: 0.01));
    expect(today.top - o1.bottom, moreOrLessEquals(8, epsilon: 0.01));
    expect(n1.top - today.bottom, moreOrLessEquals(8, epsilon: 0.01));
  });

  drained('the readers card shows the read time by day, under the name', (
    t,
  ) async {
    final yesterday = DateTime(now.year, now.month, now.day - 1, 14, 32);
    final card = await openReaders(t, [
      ReadMark(
        userId: bob.userId,
        shares: true,
        readAt: DateTime(2024, 3, 4, 14, 32),
      ),
      ReadMark(userId: cem.userId, shares: true, readAt: yesterday),
    ]);
    expect(t.takeException(), isNull, reason: 'no overflow');
    final bobRow = find.byKey(ValueKey('reader-${bob.userId}'));
    final cemRow = find.byKey(ValueKey('reader-${cem.userId}'));
    expect(find.descendant(of: card, matching: bobRow), findsOneWidget);
    expect(
      textsIn(t, bobRow),
      contains('04.03.24 at 14:32'),
      reason: 'a read over a year ago: dd.MM.yy at HH:mm',
    );
    expect(
      textsIn(t, cemRow),
      contains('yesterday at 14:32'),
      reason: 'a read yesterday',
    );
    for (final (row, name, time) in [
      (bobRow, 'Bob', '04.03.24 at 14:32'),
      (cemRow, 'Cem', 'yesterday at 14:32'),
    ]) {
      final n = t.getRect(find.descendant(of: row, matching: find.text(name)));
      final r = t.getRect(find.descendant(of: row, matching: find.text(time)));
      expect(
        r.top,
        greaterThanOrEqualTo(n.bottom),
        reason: '$time under $name',
      );
    }
  });

  drained('a long name and "04.03.24 at 14:32" fit on one line each, no '
      'overflow', (t) async {
    await openReaders(t, [
      ReadMark(
        userId: longName.userId,
        shares: true,
        readAt: DateTime(2024, 3, 4, 14, 32),
      ),
    ]);
    expect(t.takeException(), isNull, reason: 'no overflow');
    final row = find.byKey(ValueKey('reader-${longName.userId}'));
    final name = find.descendant(
      of: row,
      matching: find.text(longName.displayName),
    );
    final time = find.descendant(
      of: row,
      matching: find.text('04.03.24 at 14:32'),
    );
    expect(name, findsOneWidget);
    expect(time, findsOneWidget);
    final card = t.getRect(find.byKey(const ValueKey('readers-card')));
    for (final f in [name, time]) {
      final r = t.getRect(f);
      expect(r.right, lessThanOrEqualTo(card.right + 0.5), reason: 'inside');
      expect(
        t
            .renderObject<RenderParagraph>(
              find.descendant(of: f, matching: find.byType(RichText)),
            )
            .size
            .height,
        lessThan(30),
        reason: 'one line',
      );
    }
    expect(t.getRect(time).top, greaterThanOrEqualTo(t.getRect(name).bottom));
  });

  drained('a bubble keeps its element when a new message arrives, also when '
      'the new one starts a day', (t) async {
    final chat = world([
      chatMessage('o1', body: 'old one', createdAt: oldDay),
      chatMessage(
        'o2',
        body: 'old two',
        createdAt: oldDay.add(const Duration(minutes: 1)),
      ),
    ]);
    await open(t, chat);
    final o1 = t.element(bubble('o1'));
    final o2 = t.element(bubble('o2'));

    chat.deliver(chatMessage('n1', body: 'new one', createdAt: DateTime.now()));
    await t.pumpAndSettle();
    expect(find.text('new one', findRichText: true), findsOneWidget);
    expect(t.takeException(), isNull);
    expect(find.text('Today'), findsOneWidget, reason: 'the new day: a chip');
    expect(identical(t.element(bubble('o2')), o2), isTrue, reason: 'o2 kept');
    expect(identical(t.element(bubble('o1')), o1), isTrue, reason: 'o1 kept');

    final n1 = t.element(bubble('n1'));
    chat.deliver(chatMessage('n2', body: 'new two', createdAt: DateTime.now()));
    await t.pumpAndSettle();
    expect(find.text('new two', findRichText: true), findsOneWidget);
    expect(t.takeException(), isNull);
    expect(identical(t.element(bubble('n1')), n1), isTrue, reason: 'n1 kept');
    expect(identical(t.element(bubble('o2')), o2), isTrue, reason: 'o2 kept');
  });
}
