import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_questions_view.dart';
import 'package:sis/features/admin_panels/presentation/admin_question_card.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../application/admin_fakes.dart';

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: const AdminQuestionsView()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late ProviderContainer container;
  late FakeAdminRepository repo;

  setUp(() {
    repo = FakeAdminRepository();
    container = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
        adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
      ],
    );
  });

  // Unmounts the screen so its poll timer is gone before the test ends.
  void scene(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
  }

  Finder header(String id) => find.byKey(ValueKey('admin-question-header-$id'));
  Finder card(String id) =>
      find.ancestor(of: header(id), matching: find.byType(AdminQuestionCard));
  bool bodyShown(String id) => find
      .descendant(of: card(id), matching: find.text('a'))
      .evaluate()
      .isNotEmpty;

  AdminItem q(String id, String text, {String? state, int seq = 1}) {
    final fields = <String, Object?>{
      'id': id,
      'question': text,
      'answers': ['a', 'b'],
    };
    if (state != null) fields['state'] = state;
    return AdminItem(
      id: 'q:$id',
      kind: 'question',
      seq: seq,
      removed: false,
      fields: fields,
    );
  }

  Future<void> load(WidgetTester t, List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
    final ctrl = container.read(adminPanelsProvider.notifier);
    await ctrl.open('reason');
    await ctrl.refresh();
    await _pump(t, container);
  }

  scene('1 only the first unanswered is open', (tester) async {
    await load(tester, [
      q('Q-1', 'first one'),
      q('Q-2', 'second one'),
      q('Q-3', 'third one'),
    ]);
    expect(bodyShown('Q-1'), true);
    expect(bodyShown('Q-2'), false);
    expect(bodyShown('Q-3'), false);
    expect(
      find.descendant(
        of: header('Q-2'),
        matching: find.textContaining('second one', findRichText: true),
      ),
      findsOneWidget,
    );
  });

  scene('2 tap toggles a collapsed card', (tester) async {
    await load(tester, [
      q('Q-1', 'first one'),
      q('Q-2', 'second one'),
      q('Q-3', 'third one'),
    ]);
    await tester.tap(header('Q-2'));
    await tester.pumpAndSettle();
    expect(bodyShown('Q-2'), true);
    await tester.tap(header('Q-2'));
    await tester.pumpAndSettle();
    expect(bodyShown('Q-2'), false);
  });

  scene('3 closed top card stays closed after refresh with same ids', (
    tester,
  ) async {
    await load(tester, [
      q('Q-1', 'first one'),
      q('Q-2', 'second one'),
      q('Q-3', 'third one'),
    ]);
    await tester.tap(header('Q-1'));
    await tester.pumpAndSettle();
    await tester.tap(header('Q-3'));
    await tester.pumpAndSettle();
    repo.fetchQueue = [
      [
        deltaRow(
          2,
          2,
          cursor: 7,
          items: [
            q('Q-1', 'first one', seq: 2),
            q('Q-2', 'second one', seq: 2),
            q('Q-3', 'third one', seq: 2),
          ],
        ),
      ],
    ];
    final ctrl = container.read(adminPanelsProvider.notifier);
    await ctrl.refresh();
    await tester.pumpAndSettle();
    expect(bodyShown('Q-1'), false);
    expect(bodyShown('Q-3'), true);
  });

  scene('4 long text wraps whole when open, first line only when closed', (
    tester,
  ) async {
    final long = 'alpha line\n${'beta words ' * 30}';
    await load(tester, [q('Q-1', long), q('Q-2', long)]);
    // Q-1 should be open by auto-open
    expect(bodyShown('Q-1'), true);
    // Check that beta words appear in Q-1 body
    expect(
      find.descendant(
        of: card('Q-1'),
        matching: find.textContaining('beta words', findRichText: true),
      ),
      findsWidgets,
    );
    // Verify no ellipsis on any Text in Q-1
    final textsQ1 = find
        .descendant(of: card('Q-1'), matching: find.byType(Text))
        .evaluate();
    var checked = 0;
    for (final e in textsQ1) {
      final t = e.widget as Text;
      if (!(t.data ?? t.textSpan?.toPlainText() ?? '').contains('beta words')) {
        continue;
      }
      checked++;
      expect(t.maxLines, isNull);
      expect(t.overflow, isNot(TextOverflow.ellipsis));
    }
    expect(checked, greaterThan(0));
    // Q-2 should be collapsed
    expect(bodyShown('Q-2'), false);
    expect(
      find.descendant(
        of: header('Q-2'),
        matching: find.textContaining('alpha line', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: header('Q-2'),
        matching: find.textContaining('beta words', findRichText: true),
      ),
      findsNothing,
    );
    final headerTexts = find
        .descendant(of: header('Q-2'), matching: find.byType(Text))
        .evaluate();
    for (final e in headerTexts) {
      final t = e.widget as Text;
      expect(t.maxLines, 1);
    }
  });

  scene('5 sending closes it and opens the next; manual choices kept', (
    tester,
  ) async {
    await load(tester, [
      q('Q-1', 'first one'),
      q('Q-2', 'second one'),
      q('Q-3', 'third one'),
      q('Q-4', 'fourth one'),
    ]);
    await tester.tap(header('Q-4'));
    await tester.pumpAndSettle();
    // Send answer on Q-1
    await tester.tap(
      find.descendant(of: card('Q-1'), matching: find.text('a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();
    expect(bodyShown('Q-1'), false);
    expect(bodyShown('Q-2'), true);
    expect(bodyShown('Q-3'), false);
    expect(bodyShown('Q-4'), true);
  });

  scene('6 waiting question is never auto-open', (tester) async {
    await load(tester, [
      q('Q-1', 'first one', state: 'waiting'),
      q('Q-2', 'second one'),
      q('Q-3', 'third one'),
    ]);
    expect(bodyShown('Q-1'), false);
    expect(bodyShown('Q-2'), true);
    expect(bodyShown('Q-3'), false);
  });

  scene('7 all waiting: none open', (tester) async {
    await load(tester, [
      q('Q-1', 'first one\nhidden more', state: 'waiting'),
      q('Q-2', 'second one\nhidden more', state: 'waiting'),
    ]);
    expect(bodyShown('Q-1'), false);
    expect(bodyShown('Q-2'), false);
    expect(find.text('a'), findsNothing);
    // A collapsed card shows only the first line, so the second line is hidden.
    expect(
      find.textContaining('hidden more', findRichText: true),
      findsNothing,
    );
  });

  scene('8 empty and newline-only text', (tester) async {
    await load(tester, [q('Q-1', ''), q('Q-2', '\n\n'), q('Q-3', 'third one')]);
    expect(tester.takeException(), isNull);
    expect(header('Q-1'), findsOneWidget);
    expect(header('Q-2'), findsOneWidget);
    expect(bodyShown('Q-1'), true);
    expect(bodyShown('Q-2'), false);
  });

  scene('9 sending a manually opened question closes it', (tester) async {
    await load(tester, [
      q('Q-1', 'first one'),
      q('Q-2', 'second one'),
      q('Q-3', 'third one'),
    ]);
    await tester.tap(header('Q-3'));
    await tester.pumpAndSettle();
    expect(bodyShown('Q-3'), true);
    await tester.tap(
      find.descendant(of: card('Q-3'), matching: find.text('a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();
    expect(bodyShown('Q-3'), false);
    expect(bodyShown('Q-1'), true);
    expect(bodyShown('Q-2'), false);
  });
}
