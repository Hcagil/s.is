// A floating card with a text field, opened low on a tall phone while the
// keyboard is up (viewInsets.bottom > 0), must lie wholly above the keyboard
// with its confirm button on screen. Written from the contract.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/presentation/custom_theme_actions.dart';
import 'package:sis/features/appearance/presentation/new_theme_card.dart';
import 'package:sis/features/chat/presentation/message_menu_card.dart';

import '../../support/l10n.dart';

const phone = Size(390, 844); // a tall iPhone, logical pixels
const keyboard = 336.0;
const anchor = Rect.fromLTWH(16, 770, 358, 52); // a row near the bottom

Finder byKey(String k) => find.byKey(ValueKey(k));

typedef Opener = void Function(BuildContext);

final cards =
    <({String name, Opener open, String card, String field, String button})>[
      (
        name: 'New theme',
        open: (c) => showNewThemeCard(c, anchor),
        card: 'new-theme-card',
        field: 'new-theme-field',
        button: 'new-theme-create',
      ),
      (
        name: 'Rename (also used by Duplicate)',
        open: (c) => showRenameThemeCard(c, anchor, 'Night'),
        card: 'theme-rename-card',
        field: 'theme-rename-field',
        button: 'theme-rename-save',
      ),
      (
        name: 'any low card with a field',
        open: (c) => showFloatingCard<void>(
          c,
          anchor: anchor,
          cardKey: const ValueKey('plain-card'),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(key: ValueKey('plain-field'), autofocus: true),
                SizedBox(height: 120),
                TextButton(
                  key: ValueKey('plain-go'),
                  onPressed: null,
                  child: Text('Create'),
                ),
              ],
            ),
          ),
        ),
        card: 'plain-card',
        field: 'plain-field',
        button: 'plain-go',
      ),
    ];

Future<BuildContext> pumpHost(WidgetTester t, {required double insets}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = phone;
  t.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  t.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
  t.view.viewInsets = FakeViewPadding(bottom: insets);
  addTearDown(t.view.reset);
  late BuildContext ctx;
  await t.pumpWidget(
    localizedApp(
      theme: sisTheme(Brightness.light),
      home: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return ctx;
}

void expectAboveKeyboard(WidgetTester t, String card, String button) {
  final top = phone.height - keyboard;
  final c = t.getRect(byKey(card));
  expect(
    c.bottom,
    lessThanOrEqualTo(top + 0.5),
    reason: 'card $c under the keyboard',
  );
  expect(c.top, greaterThanOrEqualTo(0), reason: 'card $c off the top');
  final b = t.getRect(byKey(button));
  expect(b.top, greaterThanOrEqualTo(0), reason: 'button $b off the top');
  expect(b.bottom, lessThanOrEqualTo(top + 0.5), reason: 'button $b hidden');
  expect(t.getRect(byKey(button)).overlaps(Offset.zero & phone), isTrue);
}

void main() {
  for (final c in cards) {
    testWidgets('${c.name}: opened low with the keyboard up, the card and '
        'its button lie above the keyboard', (t) async {
      final ctx = await pumpHost(t, insets: keyboard);
      c.open(ctx);
      await t.pumpAndSettle();
      expect(byKey(c.card), findsOneWidget);
      expect(byKey(c.field), findsOneWidget);
      expectAboveKeyboard(t, c.card, c.button);
    });

    testWidgets('${c.name}: the keyboard rising after the card opened moves '
        'the card above it', (t) async {
      final ctx = await pumpHost(t, insets: 0);
      c.open(ctx);
      await t.pumpAndSettle();
      t.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      await t.pumpAndSettle();
      expectAboveKeyboard(t, c.card, c.button);
    });
  }
}
