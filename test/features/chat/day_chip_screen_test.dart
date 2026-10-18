// Message dates on the real chat screen, from the contract only, mounted as
// production opens a chat (chat_launcher), fakes only at the repositories:
//  * a day chip above the first message of each local day, none same-day;
//  * bubbles keep showing the clock time only (HH:mm);
//  * the readers card shows seenTime ("yesterday at 14:32", "04.03.24 at ...");
//  * every message row keeps its own key: no duplicate-key error with chips,
//    and a bubble keeps its element (its state) when a new message arrives.
// Run under TZ=JST-9 like every unit test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
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

ChatFake world(List<Message> messages, {List<ReadMark> marks = const []}) =>
    ChatFake(self: me.userId)
      ..history['c1'] = messages
      ..roster['c1'] = [me, bob, cem]
      ..membersResult = const Ok([bob, cem])
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
        texts.any((s) => s.contains(hm(at))),
        isTrue,
        reason: 'bubble $id shows ${hm(at)}: $texts',
      );
      expect(
        texts.any(
          (s) =>
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

  drained('the readers card shows the read time by day', (t) async {
    final yesterday = DateTime(now.year, now.month, now.day - 1, 14, 32);
    await open(
      t,
      world(
        [chatMessage('m1', body: 'mine', from: me.userId, createdAt: oldDay)],
        marks: [
          ReadMark(
            userId: bob.userId,
            shares: true,
            readAt: DateTime(2024, 3, 4, 14, 32),
          ),
          ReadMark(userId: cem.userId, shares: true, readAt: yesterday),
        ],
      ),
    );
    await t.tap(find.byKey(const ValueKey('body-m1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('seen-by-m1')));
    await t.pumpAndSettle();
    final card = find.byKey(const ValueKey('readers-card'));
    expect(card, findsOneWidget, reason: 'fixture: the card opened');

    final bobRow = find.byKey(ValueKey('reader-${bob.userId}'));
    final cemRow = find.byKey(ValueKey('reader-${cem.userId}'));
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
