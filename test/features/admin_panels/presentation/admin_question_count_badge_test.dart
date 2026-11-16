import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import '../application/admin_fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

/// Builds the widget under test inside a MaterialApp with the required
/// providers and theme.  The optional [size] can be used to override the
/// logical size of the view for tests that need a specific screen size.
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AdminPanelsScreen(),
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

  /// Helper to create a conversation item.
  final AdminItem conv = AdminItem(
    id: 'c:c1',
    kind: 'talk',
    seq: 1,
    removed: false,
    fields: {
      'id': 'c1',
      'topic': 'Topic',
      'at': 1000,
      'unread': false,
      'waiting': 0,
      'conv': true,
    },
  );

  /// Finder for a badge with a given label and number.
  Finder badge(String label, String n) => find.descendant(
    of: find.widgetWithText(NavigationDestination, label),
    matching: find.text(n),
  );

  /// Expect that no badge exists for the given label.
  void expectNoBadge(String label) {
    expect(find.widgetWithText(NavigationDestination, label), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(NavigationDestination, label),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
  }

  /// Prepare initial snapshot with the given items.
  Future<void> prepareInitial(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
  }

  /// Helper to create N question items.
  List<AdminItem> qs(int n) => [for (var i = 1; i <= n; i++) qItem('Q-$i')];

  /// Helper to create a waiting question reported by the computer.
  AdminItem waitingQ(String id) => AdminItem(
    id: 'q:$id',
    kind: 'question',
    seq: 1,
    removed: false,
    fields: {
      'id': id,
      'question': 'text $id',
      'answers': ['a', 'b'],
      'state': 'waiting',
    },
  );

  /// Tap a tab by its label.
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Answer a question from this phone.
  Future<void> answer(WidgetTester tester, String id) async {
    await container.read(adminPanelsProvider.notifier).answerQuestion(id, 'a');
    await tester.pumpAndSettle();
  }

  scene('five unanswered questions show 5 on Questions', (tester) async {
    await prepareInitial([...qs(5), conv]);
    await _pump(tester, container);
    expect(badge('Questions', '5'), findsOneWidget);
  });

  scene('no questions: no badge on Questions', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    expectNoBadge('Questions');
  });

  scene('five questions, three answered: 2 on Questions', (tester) async {
    await prepareInitial([...qs(5), conv]);
    await _pump(tester, container);
    await answer(tester, 'Q-1');
    await answer(tester, 'Q-2');
    await answer(tester, 'Q-3');
    expect(badge('Questions', '2'), findsOneWidget);
  });

  scene('a question the computer reports waiting is not counted', (
    tester,
  ) async {
    await prepareInitial([qItem('Q-1'), waitingQ('Q-2'), qItem('Q-3'), conv]);
    await _pump(tester, container);
    expect(badge('Questions', '2'), findsOneWidget);
  });

  scene('all questions answered: badge hidden', (tester) async {
    await prepareInitial([...qs(2), conv]);
    await _pump(tester, container);
    await answer(tester, 'Q-1');
    await answer(tester, 'Q-2');
    expectNoBadge('Questions');
  });

  scene('badge stays visible while the Questions tab is open', (tester) async {
    await prepareInitial([...qs(5), conv]);
    await _pump(tester, container);
    await tapTab(tester, 'Questions');
    expect(badge('Questions', '5'), findsOneWidget);
  });

  scene('answering while the Questions tab is open lowers the number', (
    tester,
  ) async {
    await prepareInitial([...qs(5), conv]);
    await _pump(tester, container);
    await tapTab(tester, 'Questions');
    await answer(tester, 'Q-1');
    expect(badge('Questions', '4'), findsOneWidget);
  });

  scene('a failed send puts the number back', (tester) async {
    await prepareInitial([...qs(3), conv]);
    await _pump(tester, container);
    await answer(tester, 'Q-1');
    expect(badge('Questions', '2'), findsOneWidget);
    final a = container.read(adminPanelsProvider).answers.last;
    repo.fetchQueue.add([
      deltaRow(
        2,
        2,
        cursor: 6,
        results: [failResult(a.epoch, a.upSeq, AdminAnswerCode.notOpen)],
      ),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Questions', '3'), findsOneWidget);
  });
}
