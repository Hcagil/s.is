import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/app/grey_option.dart';
import 'package:sis/app/settings_row.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/l10n/app_localizations.dart';

/// Pumps [child] inside a localized, themed app.
Future<void> pumpIn(
  WidgetTester t,
  Widget child, {
  Locale locale = const Locale('en'),
}) => t.pumpWidget(
  MaterialApp(
    theme: sisTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  ),
);

/// What the user actually sees: every opacity layer above [f]'s render
/// object, times the alpha of [color] if the widget faded the colour instead.
double effectiveOpacity(WidgetTester t, Finder f, {Color? color}) {
  var o = color?.a ?? 1.0;
  RenderObject? r = t.renderObject(f);
  while (r != null) {
    if (r is RenderOpacity) o *= r.opacity;
    if (r is RenderAnimatedOpacity) o *= r.opacity.value;
    r = r.parent;
  }
  return o;
}

/// Every semantics node at or under [node].
List<SemanticsNode> subtree(SemanticsNode node) {
  final out = <SemanticsNode>[node];
  node.visitChildren((c) {
    out.addAll(subtree(c));
    return true;
  });
  return out;
}

void main() {
  group('GreyOption', () {
    const key = ValueKey('grey-theme');

    testWidgets('a tappable child: keyed, faded, inert, unfocusable', (
      t,
    ) async {
      final sem = t.ensureSemantics();
      var taps = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpIn(
        t,
        GreyOption(
          name: 'theme',
          label: 'Theme',
          child: TextButton(
            focusNode: focus,
            onPressed: () => taps++,
            child: const Text('Theme'),
          ),
        ),
      );

      expect(find.byKey(key), findsOneWidget);
      expect(
        effectiveOpacity(t, find.text('Theme')),
        moreOrLessEquals(SisTokens.greyOpacity),
      );
      expect(SisTokens.greyOpacity, 0.4);

      await t.tap(find.byKey(key), warnIfMissed: false);
      await t.tap(find.text('Theme'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(taps, 0, reason: 'a grey option must not act on a tap');

      focus.requestFocus();
      await t.pump();
      expect(focus.hasFocus, isFalse, reason: 'focus reached the child');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(focus.hasFocus, isFalse, reason: 'tab reached the child');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(taps, 0);

      final node = t.getSemantics(find.byKey(key));
      expect(
        node,
        isSemantics(label: 'Theme', hasEnabledState: true, isEnabled: false),
      );
      for (final n in subtree(node)) {
        expect(
          n.getSemanticsData().hasAction(SemanticsAction.tap),
          isFalse,
          reason: 'the child tap action is exposed',
        );
      }
      sem.dispose();
    });

    testWidgets('a SisSwitch child never toggles', (t) async {
      final sem = t.ensureSemantics();
      final changes = <bool>[];
      await pumpIn(
        t,
        GreyOption(
          name: 'theme',
          label: 'Dark mode',
          child: SisSwitch(value: false, onChanged: changes.add),
        ),
      );
      expect(
        effectiveOpacity(t, find.byType(SisSwitch)),
        moreOrLessEquals(0.4),
      );
      await t.tap(find.byType(SisSwitch), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(changes, isEmpty);

      final node = t.getSemantics(find.byKey(key));
      expect(
        node,
        isSemantics(
          label: 'Dark mode',
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      for (final n in subtree(node)) {
        expect(n.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      }
      sem.dispose();
    });

    for (final locale in const [Locale('en'), Locale('tr')]) {
      testWidgets('adds no text of its own ($locale)', (t) async {
        final sem = t.ensureSemantics();
        await pumpIn(
          t,
          GreyOption(name: 'x', label: 'Option', child: const Text('Option')),
          locale: locale,
        );
        final texts = find
            .descendant(
              of: find.byKey(const ValueKey('grey-x')),
              matching: find.byType(RichText),
            )
            .evaluate()
            .map((e) => (e.widget as RichText).text.toPlainText())
            .toList();
        expect(texts, ['Option']);
        final labels = subtree(
          t.getSemantics(find.byKey(const ValueKey('grey-x'))),
        ).map((n) => n.label.toLowerCase()).join(' ');
        expect(labels, isNot(contains('soon')));
        expect(labels, isNot(contains('yakında')));
        expect(find.textContaining('soon'), findsNothing);
        expect(find.textContaining('yakında'), findsNothing);
        sem.dispose();
      });
    }
  });

  group('SisSettingsRow', () {
    final chevrons = {
      Icons.chevron_right,
      Icons.chevron_right_rounded,
      Icons.arrow_forward_ios,
      Icons.arrow_forward_ios_rounded,
    };
    final chevron = find.byWidgetPredicate(
      (w) => w is Icon && chevrons.contains(w.icon),
    );

    testWidgets('shows icon, title, value and a trailing chevron', (t) async {
      await pumpIn(
        t,
        const SisSettingsRow(
          icon: Icons.language,
          title: 'Language',
          value: 'English',
        ),
      );
      expect(find.byIcon(Icons.language), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(chevron, findsOneWidget);
      final x = t.getCenter(chevron).dx;
      expect(x, greaterThan(t.getCenter(find.text('Language')).dx));
      expect(x, greaterThan(t.getCenter(find.text('English')).dx));
    });

    testWidgets('without a value, still the icon, title and chevron', (
      t,
    ) async {
      await pumpIn(
        t,
        const SisSettingsRow(icon: Icons.language, title: 'Language'),
      );
      expect(find.byIcon(Icons.language), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
      expect(chevron, findsOneWidget);
    });

    testWidgets('is at least 48 tall', (t) async {
      await pumpIn(
        t,
        const SisSettingsRow(icon: Icons.language, title: 'Language'),
      );
      expect(
        t.getSize(find.byType(SisSettingsRow)).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('a tap calls onTap', (t) async {
      var taps = 0;
      await pumpIn(
        t,
        SisSettingsRow(
          icon: Icons.language,
          title: 'Language',
          onTap: () => taps++,
        ),
      );
      await t.tap(find.text('Language'));
      await t.tap(chevron);
      await t.pumpAndSettle();
      expect(taps, 2);
    });

    testWidgets('with onTap null a tap does nothing', (t) async {
      await pumpIn(
        t,
        const SisSettingsRow(icon: Icons.language, title: 'Language'),
      );
      await t.tap(find.text('Language'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Language'), findsOneWidget);
    });
  });

  group('DeliveryTick', () {
    const rest = Color(0xFF777777);
    Icon iconOf(WidgetTester t) => t.widget<Icon>(
      find.descendant(
        of: find.byType(DeliveryTick),
        matching: find.byType(Icon),
      ),
    );
    Color shownColor(WidgetTester t) {
      final rich = t.widget<RichText>(
        find.descendant(
          of: find.byType(DeliveryTick),
          matching: find.byType(RichText),
        ),
      );
      return rich.text.style!.color!;
    }

    double opacity(WidgetTester t) => effectiveOpacity(
      t,
      find.descendant(
        of: find.byType(DeliveryTick),
        matching: find.byType(RichText),
      ),
      color: shownColor(t),
    );

    bool sameRgb(Color a, Color b) =>
        (a.r - b.r).abs() < 0.01 &&
        (a.g - b.g).abs() < 0.01 &&
        (a.b - b.b).abs() < 0.01;

    for (final (d, icon, name) in const [
      (Delivery.pending, Icons.schedule, 'schedule'),
      (Delivery.sent, Icons.done, 'done'),
      (Delivery.delivered, Icons.done_all, 'done_all'),
      (Delivery.read, Icons.done_all, 'done_all'),
    ]) {
      testWidgets('$d shows Icons.$name', (t) async {
        await pumpIn(t, DeliveryTick(delivery: d, color: rest));
        await t.pumpAndSettle();
        expect(iconOf(t).icon, icon);
      });
    }

    testWidgets('delivered is in the rest colour at 0.75', (t) async {
      await pumpIn(
        t,
        const DeliveryTick(delivery: Delivery.delivered, color: rest),
      );
      await t.pumpAndSettle();
      expect(sameRgb(shownColor(t), rest), isTrue);
      expect(opacity(t), moreOrLessEquals(0.75, epsilon: 0.01));
    });

    testWidgets('read is in the read colour at 0.95', (t) async {
      await pumpIn(t, const DeliveryTick(delivery: Delivery.read, color: rest));
      await t.pumpAndSettle();
      expect(SisTokens.tickReadColor, const Color(0xFF8FF0FF));
      expect(sameRgb(shownColor(t), SisTokens.tickReadColor), isTrue);
      expect(opacity(t), moreOrLessEquals(0.95, epsilon: 0.01));
    });

    for (final d in const [Delivery.pending, Delivery.sent]) {
      testWidgets('$d rests at 0.75, not in the read colour', (t) async {
        await pumpIn(t, DeliveryTick(delivery: d, color: rest));
        await t.pumpAndSettle();
        expect(sameRgb(shownColor(t), rest), isTrue);
        expect(opacity(t), moreOrLessEquals(0.75, epsilon: 0.01));
      });
    }

    testWidgets('size sets the icon size', (t) async {
      await pumpIn(t, const DeliveryTick(delivery: Delivery.sent, size: 20));
      expect(iconOf(t).size, 20);
      await pumpIn(t, const DeliveryTick(delivery: Delivery.sent));
      expect(iconOf(t).size, 14);
    });

    testWidgets('delivered to read animates the opacity over 0.3 s', (t) async {
      await pumpIn(
        t,
        const DeliveryTick(delivery: Delivery.delivered, color: rest),
      );
      await t.pumpAndSettle();
      await pumpIn(t, const DeliveryTick(delivery: Delivery.read, color: rest));
      await t.pump(const Duration(milliseconds: 150));
      // Mid-way the tick is either one icon at an in-between opacity, or a
      // cross-fade of the old and new icons; never the finished state.
      final glyphs = find.descendant(
        of: find.byType(DeliveryTick),
        matching: find.byType(RichText),
      );
      if (glyphs.evaluate().length == 1) {
        final mid = opacity(t);
        expect(mid, greaterThan(0.76), reason: 'no movement at 150 ms');
        expect(mid, lessThan(0.94), reason: 'already finished at 150 ms');
      } else {
        expect(glyphs, findsNWidgets(2), reason: 'cross-fade at 150 ms');
      }
      await t.pump(const Duration(milliseconds: 160));
      expect(glyphs, findsOneWidget, reason: 'not finished after 0.3 s');
      expect(opacity(t), moreOrLessEquals(0.95, epsilon: 0.01));
      expect(sameRgb(shownColor(t), SisTokens.tickReadColor), isTrue);
    });

    for (final (locale, labels) in const [
      (
        Locale('en'),
        {
          Delivery.pending: 'Sending',
          Delivery.sent: 'Sent',
          Delivery.delivered: 'Delivered',
          Delivery.read: 'Read',
        },
      ),
      (
        Locale('tr'),
        {
          Delivery.pending: 'Gönderiliyor',
          Delivery.sent: 'Gönderildi',
          Delivery.delivered: 'Teslim edildi',
          Delivery.read: 'Okundu',
        },
      ),
    ]) {
      for (final MapEntry(key: d, value: label) in labels.entries) {
        testWidgets('$d is announced as "$label" ($locale)', (t) async {
          final sem = t.ensureSemantics();
          await pumpIn(t, DeliveryTick(delivery: d), locale: locale);
          await t.pumpAndSettle();
          expect(find.bySemanticsLabel(label), findsOneWidget);
          sem.dispose();
        });
      }
    }
  });
}
