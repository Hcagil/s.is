// PollCreatePage, from its contract: send is disabled until a question and
// two options are filled in; add option disappears at 12 with the max note;
// remove shows only above two; options reorder by the handle; both switches
// start off; a dirty form asks before discarding on back, a clean one pops
// silently; the draft comes back trimmed. EN, and TR at 360 dp.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/domain/poll.dart';
import 'package:sis/features/chat/presentation/poll_create_page.dart';
import 'package:sis/l10n/app_localizations.dart';

Finder k(String s) => find.byKey(ValueKey(s));

Future<List<PollDraft?>> openTr360(WidgetTester t) =>
    open(t, locale: const Locale('tr'), size: const Size(1080, 2220));

Future<List<PollDraft?>> open(
  WidgetTester t, {
  Locale locale = const Locale('en'),
  Size size = const Size(1233, 2700),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final results = <PollDraft?>[];
  await t.pumpWidget(
    MaterialApp(
      locale: locale,
      theme: sisTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async => results.add(
                await Navigator.of(context).push<PollDraft>(
                  MaterialPageRoute(builder: (_) => const PollCreatePage()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(k('open'));
  await t.pumpAndSettle();
  return results;
}

bool sendEnabled(WidgetTester t) =>
    t.widget<FilledButton>(k('poll-send')).onPressed != null;

bool switchOn(WidgetTester t, String key) =>
    t.widget<SisSwitchTile>(k(key)).value;

void main() {
  testWidgets('send button enabled only after question and two options', (
    WidgetTester t,
  ) async {
    await open(t);
    expect(sendEnabled(t), isFalse);

    await t.enterText(k('poll-question'), 'Q');
    await t.pumpAndSettle();
    expect(sendEnabled(t), isFalse);

    await t.enterText(k('poll-option-0'), 'A');
    await t.pumpAndSettle();
    expect(sendEnabled(t), isFalse);

    await t.enterText(k('poll-option-1'), 'B');
    await t.pumpAndSettle();
    expect(sendEnabled(t), isTrue);

    await t.enterText(k('poll-question'), '   ');
    await t.pumpAndSettle();
    expect(sendEnabled(t), isFalse);
  });

  testWidgets('switches default off and toggle on tap', (WidgetTester t) async {
    await open(t);
    expect(switchOn(t, 'poll-multiple'), isFalse);
    expect(switchOn(t, 'poll-anonymous'), isFalse);

    await t.tap(k('poll-multiple'));
    await t.pumpAndSettle();
    await t.tap(k('poll-anonymous'));
    await t.pumpAndSettle();

    expect(switchOn(t, 'poll-multiple'), isTrue);
    expect(switchOn(t, 'poll-anonymous'), isTrue);
  });

  testWidgets('send returns trimmed draft', (WidgetTester t) async {
    final results = await open(t);

    await t.enterText(k('poll-question'), '  Lunch? ');
    await t.pumpAndSettle();
    await t.enterText(k('poll-option-0'), ' Pizza ');
    await t.pumpAndSettle();
    await t.enterText(k('poll-option-1'), 'Soup');
    await t.pumpAndSettle();

    await t.tap(k('poll-multiple'));
    await t.pumpAndSettle();

    await t.ensureVisible(k('poll-send'));
    await t.tap(k('poll-send'));
    await t.pumpAndSettle();

    expect(find.byType(PollCreatePage), findsNothing);
    final draft = results.single!;
    expect(draft.question, equals('Lunch?'));
    expect(draft.options, equals(['Pizza', 'Soup']));
    expect(draft.multiple, isTrue);
    expect(draft.anonymous, isFalse);
  });

  testWidgets('add option stops at 12', (WidgetTester t) async {
    await open(t);

    for (var i = 0; i < 9; i++) {
      await t.ensureVisible(k('poll-add-option'));
      await t.tap(k('poll-add-option'));
      await t.pumpAndSettle();
    }

    // Before last tap, max note should not be visible
    expect(
      find.text('You have added the maximum number of options.'),
      findsNothing,
    );

    // Final tap to reach 12 options
    await t.ensureVisible(k('poll-add-option'));
    await t.tap(k('poll-add-option'));
    await t.pumpAndSettle();

    expect(k('poll-option-11'), findsOneWidget);
    expect(k('poll-add-option'), findsNothing);
    expect(
      find.text('You have added the maximum number of options.'),
      findsOneWidget,
    );
  });

  testWidgets('remove shows only above two', (WidgetTester t) async {
    await open(t);

    expect(k('poll-option-remove-0'), findsNothing);

    await t.ensureVisible(k('poll-add-option'));
    await t.tap(k('poll-add-option'));
    await t.pumpAndSettle();

    expect(k('poll-option-remove-0'), findsOneWidget);

    await t.tap(k('poll-option-remove-0'));
    await t.pumpAndSettle();

    expect(k('poll-option-2'), findsNothing);
    expect(k('poll-option-remove-0'), findsNothing);
  });

  testWidgets('reorders options by the handle', (WidgetTester t) async {
    final results = await open(t);
    await t.ensureVisible(k('poll-question'));
    await t.pumpAndSettle();
    await t.enterText(k('poll-question'), 'Q');
    await t.ensureVisible(k('poll-option-0'));
    await t.pumpAndSettle();
    await t.enterText(k('poll-option-0'), 'A');
    await t.ensureVisible(k('poll-option-1'));
    await t.pumpAndSettle();
    await t.enterText(k('poll-option-1'), 'B');
    final handle = find.byIcon(Icons.drag_handle).first;
    final g = await t.startGesture(t.getCenter(handle));
    await t.pump(const Duration(milliseconds: 100));
    await g.moveBy(const Offset(0, 60));
    await t.pump(const Duration(milliseconds: 100));
    await g.moveBy(const Offset(0, 60));
    await t.pump(const Duration(milliseconds: 100));
    await g.up();
    await t.pumpAndSettle();
    await t.ensureVisible(k('poll-send'));
    await t.pumpAndSettle();
    await t.tap(k('poll-send'));
    await t.pumpAndSettle();
    expect(results.single!.options, equals(['B', 'A']));
  });

  testWidgets('a clean form pops silently on back', (WidgetTester t) async {
    final results = await open(t);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(PollCreatePage), findsNothing);
    expect(k('poll-discard-confirm'), findsNothing);
    expect(results.single, isNull);
  });

  testWidgets('a dirty form asks before discarding', (WidgetTester t) async {
    final results = await open(t);
    await t.ensureVisible(k('poll-question'));
    await t.pumpAndSettle();
    await t.enterText(k('poll-question'), 'Q');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(k('poll-discard-confirm'), findsOneWidget);
    expect(find.byType(PollCreatePage), findsOneWidget);
    await t.tap(k('poll-discard-cancel'));
    await t.pumpAndSettle();
    expect(find.byType(PollCreatePage), findsOneWidget);
    expect(find.text('Q'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await t.tap(k('poll-discard-confirm'));
    await t.pumpAndSettle();
    expect(find.byType(PollCreatePage), findsNothing);
    expect(results.single, isNull);
  });

  testWidgets('an option alone makes the form dirty', (WidgetTester t) async {
    await open(t);
    await t.ensureVisible(k('poll-option-0'));
    await t.pumpAndSettle();
    await t.enterText(k('poll-option-0'), 'x');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(k('poll-discard-confirm'), findsOneWidget);
  });

  testWidgets('Turkish at 360 width: no overflow up to twelve options', (
    WidgetTester t,
  ) async {
    await openTr360(t);
    expect(find.text('Yeni Anket'), findsOneWidget);
    await t.ensureVisible(k('poll-question'));
    await t.pumpAndSettle();
    await t.enterText(
      k('poll-question'),
      'Öğle yemeğinde hangisini tercih edersiniz, arkadaşlar?',
    );
    await t.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await t.ensureVisible(k('poll-add-option'));
      await t.pumpAndSettle();
      await t.tap(k('poll-add-option'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }
    expect(find.text('En yüksek sayıda seçenek eklediniz.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
