import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_tasks_view.dart';
import 'package:sis/l10n/app_localizations.dart';

/// Helper to build the widget under test inside a MaterialApp with the
/// required providers and theme.  The optional [textScale] can be used to
/// override the logical text scale for tests that need a specific scaling.
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(320, 1200);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: const AdminTasksView()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late ProviderContainer container;
  late FakeAdminRepository repo;

  const taskName =
      'Neutral sample task name that is deliberately long so that it needs several lines on a narrow phone screen';
  const taskChange =
      'Neutral sample sentence describing what will change, written long on purpose so that it needs many lines on a narrow phone screen at a large text size.';

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

  tearDown(() => container.dispose());

  Future<void> prepareTaskSnapshot() async {
    final item = AdminItem(
      id: 't:T-M-001',
      kind: 'task',
      seq: 1,
      removed: false,
      fields: {'id': 'T-M-001', 'name': taskName, 'change': taskChange},
    );
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [item]),
      ],
    ];
    container.listen(adminPanelsProvider, (_, _) {});
    await container.read(adminPanelsProvider.notifier).open('r');
    await container.read(adminPanelsProvider.notifier).refresh();
    expect(container.read(adminPanelsProvider).hasSnapshot, isTrue);
  }

  // Test that the task name and change text are fully visible at different scales.
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'tasks item shows full name and sentence unclipped at 320px, scale $scale',
      (tester) async {
        await prepareTaskSnapshot();
        await _pump(tester, container, textScale: scale);
        final nameF = find.text(taskName);
        final changeF = find.text(taskChange);
        expect(nameF, findsOneWidget);
        expect(changeF, findsOneWidget);

        for (final f in [nameF, changeF]) {
          final w = tester.widget<Text>(f);
          expect(w.maxLines, isNull);
          expect(w.overflow, isNot(TextOverflow.ellipsis));
          expect(
            tester.renderObject<RenderParagraph>(f).didExceedMaxLines,
            isFalse,
          );

          final ctx = tester.element(f);
          final effectiveSize = DefaultTextStyle.of(ctx).style
              .merge(w.style)
              .fontSize!;
          final bodySize = Theme.of(ctx).textTheme.bodyMedium!.fontSize!;
          expect(effectiveSize, greaterThanOrEqualTo(bodySize));
        }

        expect(tester.takeException(), isNull);
      },
    );
  }

  // Test that tapping the task shows the Go and Discard buttons.
  for (final scale in [1.0, 2.0]) {
    testWidgets('tapping task shows go and discard buttons at scale $scale', (
      tester,
    ) async {
      await prepareTaskSnapshot();
      await _pump(tester, container, textScale: scale);
      await tester.tap(find.byKey(const ValueKey('admin-task-T-M-001')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('admin-task-go-T-M-001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('admin-task-discard-T-M-001')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
