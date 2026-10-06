// A tap on a message (Update 1 slice 7), through the chat as production
// opens it (chat_launcher: sisTheme, openConversation, a phone-sized view),
// fakes only at the repository boundaries. Written from the contract only:
//  * a tap opens the message (tappedMessageProvider); a second tap closes
//    it; opening another replaces it; changing conversation closes it;
//  * while open: the "Seen by" pill (seen-by-<id>) above my own, undeleted
//    message when it has readers; the reactions bar (reactions-bar-<id>)
//    below any message that can take a reaction;
//  * the pill opens the readers card (readers-card, reader-<userId>); its
//    title (readers-title) closes it; the pill is lit while it is open;
//  * the bar's emoji (reaction-pick-<id>-<emoji>) react; the one already
//    picked is lit, and tapping it again removes the reaction; "more"
//    (reaction-more-<id>) opens the picker (reaction-picker-<emoji>);
//  * a failed reaction rolls back and the screen shows an error notice;
//  * system chats: no tap extras and no long-press card.
// Run under TZ=JST-9 like every unit test.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';
import '../../support/reaction_fakes.dart';
import '../../support/sis_ui.dart';

final sent = DateTime.now().subtract(const Duration(minutes: 30));

Message mine(String id, {MessageDeletion? deletion}) => chatMessage(
  id,
  body: deletion == null ? 'mine $id' : '',
  from: me.userId,
  createdAt: sent,
  deletion: deletion,
);

Message theirs(String id) =>
    chatMessage(id, body: 'theirs $id', createdAt: sent);

/// Bob has read everything up to now and shares read receipts.
final bobRead = ReadMark(
  userId: bob.userId,
  shares: true,
  readAt: DateTime.now(),
  deliveredAt: DateTime.now(),
);

ChatFake world(
  List<Message> messages, {
  List<ReadMark> marks = const [],
  String id = 'c1',
  bool system = false,
}) => ChatFake(self: me.userId)
  ..history[id] = messages
  ..roster[id] = [me, bob, cem]
  ..membersResult = const Ok([bob, cem])
  ..readMarksData[id] = marks
  ..conversationsResult = Ok([
    Conversation(id: id, title: 'Bob', isSystem: system),
    const Conversation(id: 'c2', title: 'Work'),
  ]);

/// Opens chat [id] of [chat] the way the chat list does.
Future<ProviderContainer> open(
  WidgetTester t,
  ChatFake chat, {
  ReactionFake? reactions,
  String id = 'c1',
}) async {
  final c = await pumpLauncher(
    t,
    (context, ref) => openConversation(context, ref, id, title: 'Bob'),
    chat: chat,
    reactions: reactions,
  );
  expect(find.byType(MessageScreen), findsOneWidget, reason: 'never opened');
  return c;
}

Finder pill(String id) => find.byKey(ValueKey('seen-by-$id'));
Finder bar(String id) => find.byKey(ValueKey('reactions-bar-$id'));
Finder pick(String id, String e) =>
    find.byKey(ValueKey('reaction-pick-$id-$e'));
Finder chip(String id, String e) =>
    find.byKey(ValueKey('reaction-chip-$id-$e'));
final readersCard = find.byKey(const ValueKey('readers-card'));
final card = find.byKey(const ValueKey('message-menu'));

/// The emoji the bar of [id] offers, left to right.
List<String> picks(WidgetTester t, String id) {
  final prefix = 'reaction-pick-$id-';
  final found = [
    for (final e
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(prefix),
            )
            .evaluate())
      (
        (e.widget.key! as ValueKey<String>).value.substring(prefix.length),
        t.getTopLeft(find.byKey(e.widget.key!)).dx,
      ),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final f in found) f.$1];
}

/// Everything that paints a colour or a border under [f]: what "lit" can
/// change. Compared, never asserted against a particular value.
List<Object?> look(WidgetTester t, Finder f) => [
  for (final e
      in find
          .descendant(of: f, matching: find.byWidgetPredicate((_) => true))
          .evaluate())
    switch (e.widget) {
      Container(:final decoration, :final color) => (decoration, color),
      DecoratedBox(:final decoration) => decoration,
      Material(:final color, :final shape) => (color, shape),
      Ink(:final decoration) => decoration,
      Text(:final style) => style?.color,
      Icon(:final color) => color,
      _ => null,
    },
].nonNulls.toList();

/// The colour on screen at logical [at], read back from what was painted
/// (every route, the card's dim included).
Future<Color> pixel(WidgetTester t, Offset at) async {
  final view = t.binding.renderViews.first;
  final size = t.view.physicalSize;
  final bytes = await t.runAsync(() async {
    final image = await (view.debugLayer! as OffsetLayer).toImage(
      Offset.zero & size,
    );
    final data = await image.toByteData();
    image.dispose();
    return data!;
  });
  final dpr = t.view.devicePixelRatio;
  final x = (at.dx * dpr).round();
  final y = (at.dy * dpr).round();
  final i = (y * size.width.round() + x) * 4;
  return Color.fromARGB(
    bytes!.getUint8(i + 3),
    bytes.getUint8(i),
    bytes.getUint8(i + 1),
    bytes.getUint8(i + 2),
  );
}

/// How much of [before]'s brightness is left in [after] (1 = untouched).
double kept(Color before, Color after) {
  double v(Color c) => c.r + c.g + c.b;
  return v(after) / v(before);
}

/// Opens a card off [opening] and checks the spot [inside] it (the anchor)
/// stays at full brightness while the screen's edge on the same row drops to
/// about 27%: one dim, with a hole over the anchor. Returns once open.
Future<void> expectLitWhile(
  WidgetTester t,
  Offset inside,
  Future<void> Function() opening,
) async {
  final edge = Offset(6, inside.dy);
  final insideBefore = await pixel(t, inside);
  final edgeBefore = await pixel(t, edge);
  await opening();
  await t.pumpAndSettle();
  final edgeKept = kept(edgeBefore, await pixel(t, edge));
  final insideKept = kept(insideBefore, await pixel(t, inside));
  expect(
    edgeKept,
    closeTo(0.27, 0.05),
    reason: 'the rest of the screen is at about 27% brightness',
  );
  expect(
    insideKept,
    closeTo(1.0, 0.05),
    reason: 'the anchor is at full brightness, not dimmed',
  );
}

String? tapped(ProviderContainer c) => c.read(tappedMessageProvider);

Future<void> tapBubble(WidgetTester t, String id) async {
  await t.tap(find.byKey(ValueKey('body-$id')));
  await t.pumpAndSettle();
}

/// Records every setReaction and answers it with [answer] (default: the
/// server rules) after a short, real-feeling delay.
List<(String, String?)> recordSets(ReactionFake fake, {Result<void>? answer}) {
  final calls = <(String, String?)>[];
  fake.onSet = (id, emoji) async {
    calls.add((id, emoji));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return answer ?? fake.serverSet(id, emoji);
  };
  return calls;
}

/// Every test ends by letting the fakes' zero-delay timers (the reaction
/// usage read the bar starts) run, so none is left pending at teardown.
void drained(String description, WidgetTesterCallback body) =>
    testWidgets(description, (t) async {
      await body(t);
      await t.pump(const Duration(milliseconds: 50));
    });

void main() {
  group('the tap toggle', () {
    drained('a tap opens the message; a second tap closes it', (t) async {
      final c = await open(t, world([theirs('m1')]));
      expect(tapped(c), isNull);
      expect(bar('m1'), findsNothing);

      await tapBubble(t, 'm1');
      expect(tapped(c), 'm1');
      expect(bar('m1'), findsOneWidget);
      expect(card, findsNothing, reason: 'a tap opens no card');

      await tapBubble(t, 'm1');
      expect(tapped(c), isNull);
      expect(bar('m1'), findsNothing);
    });

    drained('one open at a time: opening another replaces it', (t) async {
      final c = await open(
        t,
        world([theirs('m1'), mine('m2')], marks: [bobRead]),
      );
      await tapBubble(t, 'm1');
      expect(bar('m1'), findsOneWidget);

      await tapBubble(t, 'm2');
      expect(tapped(c), 'm2');
      expect(bar('m1'), findsNothing);
      expect(bar('m2'), findsOneWidget);
      expect(pill('m2'), findsOneWidget);
    });

    drained('changing conversation closes the open message', (t) async {
      final c = await open(t, world([theirs('m1')]));
      await tapBubble(t, 'm1');
      expect(tapped(c), 'm1');

      c.read(openConversationProvider.notifier).open('c2');
      await t.pump();
      expect(tapped(c), isNull);
    });

    drained('leaving the chat closes it: back in, nothing is open', (t) async {
      final c = await open(t, world([theirs('m1')]));
      await tapBubble(t, 'm1');
      expect(tapped(c), 'm1');

      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen), findsNothing);
      expect(tapped(c), isNull);

      await t.tap(launcher);
      await settle(t);
      expect(bar('m1'), findsNothing);
    });
  });

  group('the Seen by pill', () {
    drained('above my own message with readers, only while open', (t) async {
      await open(t, world([mine('m1')], marks: [bobRead]));
      expect(pill('m1'), findsNothing, reason: 'closed: no pill');

      await tapBubble(t, 'm1');
      expect(pill('m1'), findsOneWidget);
      expect(
        t.getCenter(pill('m1')).dy,
        lessThan(t.getTopLeft(find.byKey(const ValueKey('body-m1'))).dy),
        reason: 'above the bubble',
      );

      await tapBubble(t, 'm1');
      expect(pill('m1'), findsNothing);
    });

    drained('never on somebody else\'s message', (t) async {
      await open(
        t,
        world(
          [theirs('m1')],
          marks: [
            bobRead,
            ReadMark(userId: cem.userId, shares: true, readAt: DateTime.now()),
          ],
        ),
      );
      await tapBubble(t, 'm1');
      expect(bar('m1'), findsOneWidget, reason: 'it did open');
      expect(pill('m1'), findsNothing);
    });

    final unread = <String, List<ReadMark>>{
      'no marks at all': [],
      'read before it was sent': [
        ReadMark(
          userId: bob.userId,
          shares: true,
          readAt: sent.subtract(const Duration(minutes: 5)),
        ),
      ],
      'read status not shared': [ReadMark(userId: bob.userId, shares: false)],
    };
    for (final MapEntry(key: why, value: marks) in unread.entries) {
      drained('none when nobody has read it: $why', (t) async {
        await open(t, world([mine('m1')], marks: marks));
        await tapBubble(t, 'm1');
        expect(bar('m1'), findsOneWidget, reason: 'it did open');
        expect(pill('m1'), findsNothing);
      });
    }

    drained('none on my deleted message, and no reactions bar', (t) async {
      final c = await open(
        t,
        world(
          [mine('d1', deletion: MessageDeletion.placeholder), mine('m1')],
          marks: [bobRead],
        ),
      );
      await t.tap(find.byKey(const ValueKey('message-d1')));
      await t.pumpAndSettle();
      expect(pill('d1'), findsNothing);
      expect(bar('d1'), findsNothing);
      expect(c.read(replyingToProvider), isNull);

      await tapBubble(t, 'm1');
      expect(pill('m1'), findsOneWidget, reason: 'the control: shown');
    });

    drained('opens the readers card; its title closes it; lit while '
        'open', (t) async {
      await open(t, world([mine('m1')], marks: [bobRead]));
      await tapBubble(t, 'm1');
      final r = t.getRect(pill('m1'));

      await expectLitWhile(
        t,
        Offset(r.left + 3, r.center.dy),
        () => t.tap(pill('m1')),
      );
      expect(readersCard, findsOneWidget);
      expect(
        find.descendant(
          of: readersCard,
          matching: find.byKey(ValueKey('reader-${bob.userId}')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: readersCard, matching: find.text(bob.displayName)),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('reader-${cem.userId}')), findsNothing);

      await t.tap(find.byKey(const ValueKey('readers-title')));
      await t.pumpAndSettle();
      expect(readersCard, findsNothing);
      expect(pill('m1'), findsOneWidget, reason: 'the message stays open');
    });
  });

  group('the reactions bar', () {
    drained('below the message; a pick reacts and shows the chip', (t) async {
      final fake = ReactionFake();
      final sets = recordSets(fake);
      await open(t, world([theirs('m1')]), reactions: fake);
      await tapBubble(t, 'm1');

      expect(
        t.getTopLeft(bar('m1')).dy,
        greaterThan(t.getCenter(find.byKey(const ValueKey('body-m1'))).dy),
        reason: 'below the bubble',
      );
      final offered = picks(t, 'm1');
      expect(offered, isNotEmpty);
      final e = offered.first;

      await t.tap(pick('m1', e));
      await t.pumpAndSettle();
      expect(sets, [('m1', e)]);
      expect(chip('m1', e), findsOneWidget);
      expect(notice, findsNothing);
    });

    drained('the picked emoji is lit; tapping it again removes it', (t) async {
      final fake = ReactionFake()
        ..seed('c1', [
          const Reaction(messageId: 'm1', userId: 'u1', emoji: '👍'),
        ]);
      final sets = recordSets(fake);
      await open(t, world([theirs('m1')]), reactions: fake);
      expect(chip('m1', '👍'), findsOneWidget, reason: 'precondition');
      await tapBubble(t, 'm1');

      final offered = picks(t, 'm1');
      expect(offered, contains('👍'));
      final other = offered.firstWhere((e) => e != '👍');
      expect(
        look(t, pick('m1', '👍')),
        isNot(look(t, pick('m1', other))),
        reason: 'the picked one is lit, the others are not',
      );

      await t.tap(pick('m1', '👍'));
      await t.pumpAndSettle();
      expect(sets, [('m1', null)], reason: 'react(id, null) removes it');
      expect(chip('m1', '👍'), findsNothing);
    });

    drained('more opens the picker; its emoji reacts', (t) async {
      final fake = ReactionFake();
      final sets = recordSets(fake);
      await open(t, world([theirs('m1')]), reactions: fake);
      await tapBubble(t, 'm1');

      await t.tap(find.byKey(const ValueKey('reaction-more-m1')));
      await t.pumpAndSettle();
      final picker = find.byKey(const ValueKey('reaction-picker'));
      expect(picker, findsOneWidget);
      final one = find.descendant(
        of: picker,
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('reaction-picker-'),
        ),
      );
      expect(one, findsWidgets);
      final key = t.widget(one.first).key! as ValueKey<String>;
      final e = key.value.substring('reaction-picker-'.length);

      await t.tap(find.byKey(key));
      await t.pumpAndSettle();
      expect(sets, [('m1', e)]);
      expect(chip('m1', e), findsOneWidget);
    });

    drained('a refused reaction rolls back and says so', (t) async {
      final fake = ReactionFake();
      final sets = recordSets(fake, answer: const Err(ProviderFailure('no')));
      await open(t, world([theirs('m1')]), reactions: fake);
      await tapBubble(t, 'm1');
      final e = picks(t, 'm1').first;

      await t.tap(pick('m1', e));
      await t.pumpAndSettle();
      expect(sets, [('m1', e)]);
      expect(chip('m1', e), findsNothing, reason: 'rolled back');
      expect(notice, findsOneWidget, reason: 'the screen reports it');
      await drainNotice(t);
    });

    drained('a refused removal puts the reaction back and says so', (t) async {
      final fake = ReactionFake()
        ..seed('c1', [
          const Reaction(messageId: 'm1', userId: 'u1', emoji: '👍'),
        ]);
      recordSets(fake, answer: const Err(NetworkFailure('offline')));
      await open(t, world([theirs('m1')]), reactions: fake);
      await tapBubble(t, 'm1');

      await t.tap(pick('m1', '👍'));
      await t.pumpAndSettle();
      expect(chip('m1', '👍'), findsOneWidget, reason: 'rolled back');
      expect(notice, findsOneWidget);
      await drainNotice(t);
    });
  });

  group('the long-press card, per kind of message', () {
    List<String> rows(WidgetTester t) {
      final found = [
        for (final e
            in find
                .descendant(
                  of: card,
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w.key is ValueKey<String> &&
                        (w.key! as ValueKey<String>).value.startsWith('menu-'),
                  ),
                )
                .evaluate())
          (
            (e.widget.key! as ValueKey<String>).value.substring(5),
            t.getTopLeft(find.byKey(e.widget.key!)).dy,
          ),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [for (final f in found) f.$1];
    }

    final old = DateTime.now().subtract(const Duration(hours: 7));
    final kinds = <String, (Message, List<String>)>{
      'my fresh text': (
        mine('k'),
        [
          'reply',
          'copy',
          'forward',
          'edit',
          'pin',
          'delete-for-me',
          'delete-for-everyone',
        ],
      ),
      'my 7 h old text': (
        chatMessage('k', body: 'old', from: me.userId, createdAt: old),
        [
          'reply',
          'copy',
          'forward',
          'pin',
          'delete-for-me',
          'delete-for-everyone',
        ],
      ),
      'somebody else\'s text': (
        theirs('k'),
        ['reply', 'copy', 'forward', 'pin', 'delete-for-me'],
      ),
      'my deleted message': (
        mine('k', deletion: MessageDeletion.placeholder),
        ['delete-for-me'],
      ),
    };
    for (final MapEntry(key: kind, value: (m, expected)) in kinds.entries) {
      drained(kind, (t) async {
        await open(t, world([m]));
        await t.longPress(find.byKey(const ValueKey('message-k')));
        await t.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(rows(t), expected);
        expect(
          find.byKey(const ValueKey('grey-pin')),
          expected.contains('pin') ? findsOneWidget : findsNothing,
        );
      });
    }

    drained('a pending message opens no card', (t) async {
      await pumpLauncher(
        t,
        (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
        chat: world([chatMessage('p', from: me.userId, pending: true)]),
        tap: false,
      );
      await t.tap(launcher);
      // A pending photo spins forever: pump a fixed while, never settle.
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.longPress(find.byKey(const ValueKey('message-p')));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('message-p')), findsOneWidget);
      expect(card, findsNothing);
    });

    drained('the long-pressed bubble is highlighted', (t) async {
      await open(t, world([theirs('m1')]));
      await expectLitWhile(
        t,
        t.getCenter(find.byKey(const ValueKey('body-m1'))),
        () => t.longPress(find.byKey(const ValueKey('message-m1'))),
      );
      expect(card, findsOneWidget);
    });
  });

  group('a system chat', () {
    drained('a tap shows nothing; a long-press opens no card', (t) async {
      final c = await open(
        t,
        world(
          [
            for (final (id, from) in [('m1', me.userId), ('m2', bob.userId)])
              Message(
                id: id,
                conversationId: 's1',
                senderId: from,
                body: 'from $from',
                createdAt: sent,
              ),
          ],
          marks: [bobRead],
          id: 's1',
          system: true,
        ),
        id: 's1',
      );
      expect(
        find.byKey(const ValueKey('composer-system')),
        findsOneWidget,
        reason: 'precondition: the screen knows it is the system chat',
      );
      for (final (id, from) in [('m1', me.userId), ('m2', bob.userId)]) {
        // The system chat renders its own cards, so find the words.
        final words = find.text('from $from');
        expect(words, findsOneWidget, reason: 'precondition: $id is shown');
        await t.tap(words);
        await t.pumpAndSettle();
        expect(bar(id), findsNothing, reason: id);
        expect(pill(id), findsNothing, reason: id);
        expect(tapped(c), isNull, reason: id);

        await t.longPress(words);
        await t.pumpAndSettle();
        expect(card, findsNothing, reason: id);
      }
    });
  });
}
