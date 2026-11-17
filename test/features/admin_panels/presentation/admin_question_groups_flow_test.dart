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

  AdminItem q(
    String id, {
    String topic = 'chat',
    String sub = '',
    String? conv,
  }) {
    final fields = <String, Object?>{
      'id': id,
      'question': 'text $id',
      'answers': ['a', 'b'],
      'topic': topic,
      'sub': sub,
    };
    if (conv != null) fields['conv'] = conv;
    return AdminItem(
      id: 'q:$id',
      kind: 'question',
      seq: 1,
      removed: false,
      fields: fields,
    );
  }

  Finder convK(String id) => find.byKey(ValueKey('admin-question-conv-$id'));
  Finder hdr(String id) => find.byKey(ValueKey('admin-question-header-$id'));

  Future<void> load(WidgetTester t, List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
    final ctrl = container.read(adminPanelsProvider.notifier);
    await ctrl.open('reason');
    await ctrl.refresh();
    await _pump(t, container);
  }

  scene('1 from line shown when conv set', (tester) async {
    await load(tester, [q('Q-1', conv: 'c-12')]);
    expect(convK('Q-1'), findsOneWidget);
    expect(find.text('from c-12'), findsOneWidget);
  });

  scene('2 no from line when conv absent', (tester) async {
    await load(tester, [q('Q-1')]);
    expect(convK('Q-1'), findsNothing);
    expect(find.textContaining('from c-'), findsNothing);
  });

  scene('3 from line only on the question that has it', (tester) async {
    await load(tester, [q('Q-1', sub: 's1', conv: 'c-7'), q('Q-2', sub: 's1')]);
    await tester.tap(header('Q-2'));
    await tester.pumpAndSettle();
    expect(hdr('Q-2'), findsOneWidget);
    expect(bodyShown('Q-2'), true);
    expect(convK('Q-1'), findsOneWidget);
    expect(convK('Q-2'), findsNothing);
  });

  scene('4 answered question stays and next in same sub stays open', (
    tester,
  ) async {
    await load(tester, [
      q('Q-1', sub: 's1'),
      q('Q-2', sub: 's1'),
      q('Q-3', topic: 'tools'),
    ]);
    container.listen(adminPanelsProvider, (_, _) {});
    await tester.tap(
      find.descendant(of: card('Q-1'), matching: find.text('a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();
    final ctrl = container.read(adminPanelsProvider.notifier);
    final a = container.read(adminPanelsProvider).answers.last;
    repo.fetchQueue = [
      [
        deltaRow(2, 2, cursor: 7, results: [okResult(a.epoch, a.upSeq)]),
      ],
    ];
    await ctrl.refresh();
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminQuestionsView)),
    );
    expect(find.text(l.adminWaiting), findsOneWidget);
    expect(hdr('Q-1'), findsOneWidget);
    expect(hdr('Q-2'), findsOneWidget);
    expect(bodyShown('Q-2'), true);
  });

  scene('5 next unanswered opens in another group', (tester) async {
    await load(tester, [
      q('Q-1', topic: 'chat', sub: 's1'),
      q('Q-2', topic: 'tools', sub: 's2'),
    ]);
    container.listen(adminPanelsProvider, (_, _) {});
    expect(hdr('Q-2'), findsNothing);
    await tester.tap(
      find.descendant(of: card('Q-1'), matching: find.text('a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();
    final ctrl = container.read(adminPanelsProvider.notifier);
    final a = container.read(adminPanelsProvider).answers.last;
    repo.fetchQueue = [
      [
        deltaRow(2, 2, cursor: 7, results: [okResult(a.epoch, a.upSeq)]),
      ],
    ];
    await ctrl.refresh();
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminQuestionsView)),
    );
    expect(find.text(l.adminWaiting), findsOneWidget);
    expect(hdr('Q-1'), findsOneWidget);
    expect(hdr('Q-2'), findsOneWidget);
    expect(bodyShown('Q-2'), true);
  });
}
