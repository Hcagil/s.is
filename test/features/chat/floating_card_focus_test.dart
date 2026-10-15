// showFloatingCard's keepFocus and the Open-in-Maps card, from the contract
// (fix/tester-findings):
//  * keepFocus true: a focused text field stays focused while the card is
//    open and after it closes;
//  * keepFocus false (the default): unchanged, the card takes the focus;
//  * confirmOpenInMaps opens with the field still focused.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/presentation/message_menu_card.dart';
import 'package:sis/features/chat/presentation/open_in_maps_card.dart';
import 'package:sis/l10n/app_localizations.dart';

const anchor = Rect.fromLTWH(20, 500, 40, 40);
const cardKey = ValueKey('card');
final field = find.byKey(const ValueKey('field'));

/// A screen with one text field; returns a context under the Navigator.
Future<BuildContext> host(WidgetTester t) async {
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: sisTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return const Padding(
              padding: EdgeInsets.only(top: 100),
              child: TextField(key: ValueKey('field')),
            );
          },
        ),
      ),
    ),
  );
  await t.tap(field);
  await t.pumpAndSettle();
  expect(focused(t), isTrue, reason: 'precondition: typing');
  return ctx;
}

bool focused(WidgetTester t) => t
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('field'), skipOffstage: false),
        matching: find.byType(EditableText, skipOffstage: false),
      ),
    )
    .focusNode
    .hasFocus;

Widget body() => const SizedBox(key: cardKey, width: 100, height: 100);

void main() {
  testWidgets('keepFocus true: focused while open and after it closes', (
    t,
  ) async {
    final ctx = await host(t);
    showFloatingCard<void>(ctx, anchor: anchor, keepFocus: true, child: body());
    await t.pumpAndSettle();
    expect(find.byKey(cardKey), findsOneWidget);
    expect(focused(t), isTrue, reason: 'while open');

    Navigator.of(ctx).pop();
    await t.pumpAndSettle();
    expect(find.byKey(cardKey), findsNothing);
    expect(focused(t), isTrue, reason: 'after close');
  });

  testWidgets('the default takes the focus from the field', (t) async {
    final ctx = await host(t);
    showFloatingCard<void>(ctx, anchor: anchor, child: body());
    await t.pumpAndSettle();
    expect(find.byKey(cardKey), findsOneWidget);
    expect(focused(t), isFalse, reason: 'the card took it');
  });

  testWidgets('Open in Maps: the field keeps the focus, open and closed', (
    t,
  ) async {
    final ctx = await host(t);
    final result = confirmOpenInMaps(ctx, place: 'Moda');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-maps-card')), findsOneWidget);
    expect(focused(t), isTrue, reason: 'while open');

    await t.tap(find.byKey(const ValueKey('open-maps-cancel')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-maps-card')), findsNothing);
    expect(await result, isNot(isTrue), reason: 'cancel opens nothing');
    expect(focused(t), isTrue, reason: 'after close');
  });
}
