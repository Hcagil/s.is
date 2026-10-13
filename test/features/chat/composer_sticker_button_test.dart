// The sticker button (stickers 10a, round 4), in a chat opened as production
// opens it. Written from the contract only:
//  * `composer-stickers` sits inside the text field (`composer-field`), at
//    its end edge: right in LTR, left in RTL;
//  * closed panel: Icons.sticky_note_2_outlined; open panel: a keyboard icon;
//  * a tap toggles the sticker panel, which opens IN PLACE OF the keyboard
//    (the field gives up focus); tapping the field brings the keyboard back;
//  * the tap target is at least 48 x 48.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/chat_launcher.dart';
import '../../support/sticker_fakes.dart';

Finder k(String key) => find.byKey(ValueKey(key));
final button = k('composer-stickers');
final panel = k('sticker-panel');

final keyboardIcons = {
  Icons.keyboard,
  Icons.keyboard_outlined,
  Icons.keyboard_rounded,
  Icons.keyboard_sharp,
  Icons.keyboard_alt,
  Icons.keyboard_alt_outlined,
  Icons.keyboard_alt_rounded,
  Icons.keyboard_alt_sharp,
};

Future<void> open(WidgetTester t, {TextDirection? direction}) async {
  await pumpLauncher(
    t,
    (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
    direction: direction,
    overrides: [
      stickerRepositoryProvider.overrideWithValue(StickerRepoFake()),
      recentStickerStoreProvider.overrideWithValue(RecentStickerStoreFake([])),
    ],
  );
  await t.pumpAndSettle();
}

/// The icons drawn inside the button.
Set<IconData?> icons(WidgetTester t) => {
  for (final e
      in find.descendant(of: button, matching: find.byType(Icon)).evaluate())
    (e.widget as Icon).icon,
};

void main() {
  for (final dir in TextDirection.values) {
    testWidgets('inside the field, at its end edge (${dir.name})', (t) async {
      await open(t, direction: dir);
      expect(
        find.descendant(of: composer, matching: button),
        findsOneWidget,
        reason: 'the button is part of the text field',
      );
      final f = t.getRect(composer);
      final b = t.getRect(button);
      expect(f.contains(b.center), isTrue, reason: 'drawn inside the field');
      if (dir == TextDirection.ltr) {
        expect(b.center.dx, greaterThan(f.center.dx), reason: 'right half');
        expect(f.right - b.right, lessThanOrEqualTo(16), reason: 'at the end');
      } else {
        expect(b.center.dx, lessThan(f.center.dx), reason: 'left half');
        expect(b.left - f.left, lessThanOrEqualTo(16), reason: 'at the start');
      }
    });
  }

  testWidgets('a tap target of at least 48 x 48', (t) async {
    await open(t);
    final s = t.getSize(button);
    expect(s.width, greaterThanOrEqualTo(48));
    expect(s.height, greaterThanOrEqualTo(48));
  });

  testWidgets('a tap toggles the panel and swaps the icon', (t) async {
    await open(t);
    expect(panel, findsNothing);
    expect(icons(t), {Icons.sticky_note_2_outlined});

    await t.tap(button);
    await t.pumpAndSettle();
    expect(panel, findsOneWidget);
    final open1 = icons(t);
    expect(open1, hasLength(1));
    expect(keyboardIcons, contains(open1.single), reason: 'keyboard icon');

    await t.tap(button);
    await t.pumpAndSettle();
    expect(panel, findsNothing);
    expect(icons(t), {Icons.sticky_note_2_outlined});
    expect(composerFocused(t), isTrue, reason: 'the keyboard takes its place');
  });

  testWidgets('the panel opens in place of the keyboard; tapping the field '
      'brings the keyboard back', (t) async {
    await open(t);
    await t.tap(composer);
    await t.pumpAndSettle();
    expect(composerFocused(t), isTrue, reason: 'precondition: keyboard up');

    await t.tap(button);
    await t.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(composerFocused(t), isFalse, reason: 'the keyboard made way');

    // Tap the text area, clear of the button at the end.
    final f = t.getRect(composer);
    await t.tapAt(f.centerLeft + const Offset(12, 0));
    await t.pumpAndSettle();
    expect(composerFocused(t), isTrue, reason: 'the keyboard is back');
    expect(panel, findsNothing, reason: 'in place of: not both at once');
    expect(icons(t), {Icons.sticky_note_2_outlined});
  });
}
