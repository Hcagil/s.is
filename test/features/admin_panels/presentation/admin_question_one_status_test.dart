import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_questions_view.dart';
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

  int statuses(AppLocalizations l) =>
      find.text(l.adminWaiting).evaluate().length +
      find.text(l.adminAnswerSending).evaluate().length;

  scene('A an answer being sent shows one status', (tester) async {
    container.listen(adminPanelsProvider, (_, _) {});
    final ctrl = container.read(adminPanelsProvider.notifier);
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();

    await _pump(tester, container);
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminQuestionsView)),
    );

    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();

    expect(statuses(l), 1);
  });

  scene('B computer marks the question waiting before its result: one status', (
    tester,
  ) async {
    container.listen(adminPanelsProvider, (_, _) {});
    final ctrl = container.read(adminPanelsProvider.notifier);
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();

    await _pump(tester, container);
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminQuestionsView)),
    );

    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();

    final waitingQ = AdminItem(
      id: 'q:Q-1',
      kind: 'question',
      seq: 2,
      removed: false,
      fields: {
        'id': 'Q-1',
        'question': 'text Q-1',
        'answers': ['a', 'b'],
        'state': 'waiting',
      },
    );
    repo.fetchQueue = [
      [
        deltaRow(2, 2, cursor: 7, items: [waitingQ]),
      ],
    ];
    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(statuses(l), 1);
  });

  scene('C ok result: only the sent status', (tester) async {
    container.listen(adminPanelsProvider, (_, _) {});
    final ctrl = container.read(adminPanelsProvider.notifier);
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();

    await _pump(tester, container);
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminQuestionsView)),
    );

    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();

    final a = container.read(adminPanelsProvider).answers.last;
    repo.fetchQueue = [
      [
        deltaRow(2, 2, cursor: 7, results: [okResult(a.epoch, a.upSeq)]),
      ],
    ];
    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(find.text(l.adminWaiting), findsOneWidget);
    expect(find.text(l.adminAnswerSending), findsNothing);
  });

  scene('D refused result: no waiting status, not-sent shown', (tester) async {
    container.listen(adminPanelsProvider, (_, _) {});
    final ctrl = container.read(adminPanelsProvider.notifier);
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();

    await _pump(tester, container);
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminQuestionsView)),
    );

    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();

    final a = container.read(adminPanelsProvider).answers.last;
    repo.fetchQueue = [
      [
        deltaRow(
          2,
          2,
          cursor: 7,
          results: [failResult(a.epoch, a.upSeq, AdminAnswerCode.notOpen)],
        ),
      ],
    ];
    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(find.text(l.adminWaiting), findsNothing);
    expect(find.text(l.adminAnswerSending), findsNothing);
    expect(find.text(l.adminAnswerNotSent), findsOneWidget);
  });
}
