// The reaction chips under a bubble, through the real message screen mounted
// the way production mounts it (chat_launcher) with the ReactionFake at the
// repository boundary. Written from the contract only:
//  * keys reactions-<messageId> (the Wrap) and reaction-chip-<id>-<emoji>;
//  * label = emoji, plus " <count>" above 1; my own chip has the primary
//    border and tint;
//  * nothing for no reactions or when the message cannot take one (pending,
//    deleted);
//  * each bubble watches only its own list: a reaction on B does not
//    rebuild A;
//  * a failed initial load shows no chips and does not crash.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/chat_launcher.dart';
import '../../support/reaction_fakes.dart';

Reaction r(String m, String u, String? e) =>
    Reaction(messageId: m, userId: u, emoji: e);

Finder chips(String id) => find.byKey(ValueKey('reactions-$id'));
Finder chip(String id, String emoji) =>
    find.byKey(ValueKey('reaction-chip-$id-$emoji'));

String label(WidgetTester t, Finder f) =>
    t.widget<Text>(find.descendant(of: f, matching: find.byType(Text))).data!;

BoxDecoration box(WidgetTester t, Finder f) =>
    t.widget<Container>(f).decoration! as BoxDecoration;

void main() {
  final two = [
    chatMessage('m1', body: 'first from bob'),
    chatMessage('m2', body: 'second, mine', from: 'u1'),
  ];

  testWidgets('chips sit under the bubble: one per emoji, count above 1', (
    t,
  ) async {
    final fake = ReactionFake()
      ..seed('c1', [
        r('m1', 'u2', '👍'),
        r('m1', 'u3', '👍'),
        r('m1', 'u1', '❤️'),
      ]);
    await openChat(t, messages: two, reactions: fake);

    expect(chips('m1'), findsOneWidget);
    expect(label(t, chip('m1', '👍')), '👍 2');
    expect(label(t, chip('m1', '❤️')), '❤️');
    expect(
      t.getTopLeft(chips('m1')).dy,
      greaterThanOrEqualTo(t.getBottomLeft(find.text('first from bob')).dy),
      reason: 'under the bubble text',
    );
    expect(chips('m2'), findsNothing, reason: 'no reactions, no row');
  });

  testWidgets('my own chip has the primary border and tint; others do not', (
    t,
  ) async {
    final fake = ReactionFake()
      ..seed('c1', [r('m1', 'u2', '👍'), r('m1', 'u1', '❤️')]);
    await openChat(t, messages: two, reactions: fake);
    final primary = Theme.of(t.element(chip('m1', '❤️'))).colorScheme.primary;

    final mine = box(t, chip('m1', '❤️'));
    expect((mine.border! as Border).top.color, primary);
    expect(mine.color, isNotNull);
    expect(mine.color!.a, lessThan(1), reason: 'a tint, not a fill');
    expect(mine.color!.toARGB32() & 0xFFFFFF, primary.toARGB32() & 0xFFFFFF);

    final theirs = box(t, chip('m1', '👍'));
    final border = theirs.border as Border?;
    expect(border?.top.color, isNot(primary));
    expect(theirs.color, isNot(mine.color));
  });

  testWidgets('a deleted message shows no chips, even with reactions in '
      'the state', (t) async {
    final fake = ReactionFake()
      ..seed('c1', [r('d1', 'u2', '👍'), r('m1', 'u2', '👍')]);
    await openChat(
      t,
      messages: [
        chatMessage('m1', body: 'stored'),
        chatMessage('d1', body: '', deletion: MessageDeletion.placeholder),
      ],
      reactions: fake,
    );
    expect(chips('m1'), findsOneWidget, reason: 'the control: shown');
    expect(chips('d1'), findsNothing);
  });

  testWidgets('a pending message shows no chips, even with reactions in '
      'the state', (t) async {
    final fake = ReactionFake()
      ..seed('c1', [r('p1', 'u2', '👍'), r('m1', 'u2', '👍')]);
    await pumpLauncher(
      t,
      (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
      messages: [
        chatMessage('m1', body: 'stored'),
        chatMessage('p1', body: 'still sending', from: 'u1', pending: true),
      ],
      reactions: fake,
      tap: false,
    );
    await t.tap(launcher);
    // A pending photo spins forever: pump a fixed while, never settle.
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(bubble('p1'), findsOneWidget);
    expect(chips('m1'), findsOneWidget, reason: 'the control: shown');
    expect(chips('p1'), findsNothing);
  });

  testWidgets('live: a reaction from another member appears, a removal '
      'disappears', (t) async {
    final fake = ReactionFake()..seed('c1', [r('m1', 'u2', '👍')]);
    await openChat(t, messages: two, reactions: fake);
    fake.others('c1', r('m2', 'u3', '🎉'));
    fake.others('c1', r('m1', 'u2', null));
    await t.pumpAndSettle();
    expect(label(t, chip('m2', '🎉')), '🎉');
    expect(chips('m1'), findsNothing);
  });

  testWidgets('a reaction on one message does not rebuild another\'s chips', (
    t,
  ) async {
    final fake = ReactionFake()
      ..seed('c1', [r('m1', 'u2', '👍'), r('m2', 'u3', '😂')]);
    await openChat(t, messages: two, reactions: fake);
    final before = t.widget(chips('m1'));

    fake.others('c1', r('m2', 'u2', '🎉'));
    await t.pumpAndSettle();

    expect(chip('m2', '🎉'), findsOneWidget, reason: 'B did change');
    expect(
      identical(t.widget(chips('m1')), before),
      isTrue,
      reason: 'A was rebuilt for a change on B',
    );
  });

  testWidgets('a failed initial load: no chips, no crash', (t) async {
    final fake = ReactionFake()
      ..seed('c1', [r('m1', 'u2', '👍')])
      ..onLoad = (_, _) async => const Err(NetworkFailure('down'));
    await openChat(t, messages: two, reactions: fake);
    expect(t.takeException(), isNull);
    expect(bubble('m1'), findsOneWidget);
    expect(bubble('m2'), findsOneWidget);
    expect(find.byKey(const ValueKey('reactions-m1')), findsNothing);
  });
}
