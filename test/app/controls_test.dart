// SIS's own switch and single-choice card, from their contract in
// lib/app/controls.dart: what a member sees, what a tap does, and what a
// screen reader is told -- never how they are drawn. Android's Switch and
// Radio are gone from the app; these must keep what those gave for free.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';

import '../support/sis_ui.dart';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: ListView(children: [child])),
);

void main() {
  group('SisSwitch', () {
    testWidgets('announces its state as a toggle and flips on tap', (t) async {
      final changes = <bool>[];
      var value = false;
      await t.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => host(
            SisSwitch(
              key: const ValueKey('s'),
              value: value,
              onChanged: (v) {
                changes.add(v);
                setState(() => value = v);
              },
            ),
          ),
        ),
      );

      expect(toggledOn(t, find.byKey(const ValueKey('s'))), isFalse);

      await t.tap(find.byKey(const ValueKey('s')));
      await t.pumpAndSettle();

      expect(changes, [true], reason: 'a tap asks for the opposite value');
      expect(toggledOn(t, find.byKey(const ValueKey('s'))), isTrue);
    });

    testWidgets('does not flip on its own: the owner decides the value', (
      t,
    ) async {
      final changes = <bool>[];
      await t.pumpWidget(
        host(
          SisSwitch(
            key: const ValueKey('s'),
            value: true,
            onChanged: changes.add,
          ),
        ),
      );

      await t.tap(find.byKey(const ValueKey('s')));
      await t.pumpAndSettle();

      expect(changes, [false]);
      expect(
        toggledOn(t, find.byKey(const ValueKey('s'))),
        isTrue,
        reason: 'the parent did not accept the change; it must still read on',
      );
    });

    testWidgets('with no onChanged it is disabled and ignores taps', (t) async {
      await t.pumpWidget(
        host(
          const SisSwitch(key: ValueKey('s'), value: false, onChanged: null),
        ),
      );

      await t.tap(find.byKey(const ValueKey('s')), warnIfMissed: false);
      await t.pumpAndSettle();

      final data = t
          .getSemantics(find.byKey(const ValueKey('s')))
          .getSemanticsData();
      expect(toggledOn(t, find.byKey(const ValueKey('s'))), isFalse);
      expect(
        data.flagsCollection.isEnabled.toString(),
        isNot(contains('isTrue')),
        reason: 'a switch nobody can change must not read as enabled',
      );
    });
  });

  group('SisSwitchTile', () {
    Widget tile({required bool value, required ValueChanged<bool> onChanged}) =>
        host(
          SisSwitchTile(
            key: const ValueKey('tile'),
            title: 'Show when I am online',
            subtitle: 'Others see a dot next to your name.',
            value: value,
            onChanged: onChanged,
          ),
        );

    testWidgets('shows its title and subtitle and contains a SisSwitch', (
      t,
    ) async {
      await t.pumpWidget(tile(value: true, onChanged: (_) {}));

      expect(find.text('Show when I am online'), findsOneWidget);
      expect(find.text('Others see a dot next to your name.'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tile')),
          matching: find.byType(SisSwitch),
        ),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
    });

    testWidgets('the whole row is one toggle to a screen reader, labelled', (
      t,
    ) async {
      await t.pumpWidget(tile(value: true, onChanged: (_) {}));

      expect(toggledOn(t, find.byKey(const ValueKey('tile'))), isTrue);
      expect(
        t.getSemantics(find.byKey(const ValueKey('tile'))).label,
        contains('Show when I am online'),
        reason: 'the toggle a screen reader lands on must say what it is',
      );
    });

    testWidgets('tapping the title (not only the switch) toggles it', (
      t,
    ) async {
      final changes = <bool>[];
      await t.pumpWidget(tile(value: false, onChanged: changes.add));

      await t.tap(find.text('Show when I am online'));
      await t.pumpAndSettle();
      expect(changes, [true]);

      await t.tap(find.byType(SisSwitch));
      await t.pumpAndSettle();
      expect(changes, [true, true], reason: 'value is still false upstream');
    });
  });

  group('SisChoiceCard', () {
    Widget group(String selected, List<String> taps) => host(
      Column(
        children: [
          for (final v in ['full', 'sender', 'none'])
            SisChoiceCard<String>(
              key: ValueKey(v),
              value: v,
              groupValue: selected,
              onChanged: taps.add,
              title: 'Option $v',
              subtitle: v == 'full' ? 'Everything' : null,
            ),
        ],
      ),
    );

    testWidgets('exactly the group value reads as selected, in a group', (
      t,
    ) async {
      await t.pumpWidget(group('sender', []));

      expect(choiceSelected(t, find.byKey(const ValueKey('sender'))), isTrue);
      expect(choiceSelected(t, find.byKey(const ValueKey('full'))), isFalse);
      expect(choiceSelected(t, find.byKey(const ValueKey('none'))), isFalse);
      expect(find.text('Option full'), findsOneWidget);
      expect(find.text('Everything'), findsOneWidget);
      expect(find.byType(Radio<String>), findsNothing);
      expect(find.byType(RadioListTile<String>), findsNothing);
    });

    testWidgets('selected shows a filled check; unselected an empty ring', (
      t,
    ) async {
      await t.pumpWidget(group('sender', []));

      // The check is the only icon a card draws; the empty ring is not one.
      Finder checkIn(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Icon),
      );
      expect(checkIn('sender'), findsOneWidget);
      expect(checkIn('full'), findsNothing);
      expect(checkIn('none'), findsNothing);
    });

    testWidgets('a tap anywhere on a card chooses that value', (t) async {
      final taps = <String>[];
      await t.pumpWidget(group('sender', taps));

      await t.tap(find.text('Option none'));
      await t.pumpAndSettle();
      await t.tap(find.text('Everything'));
      await t.pumpAndSettle();

      expect(taps, ['none', 'full']);
    });
  });
}
