import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_dashboard_view.dart';
import 'package:sis/l10n/app_localizations.dart';

/// Helper to build the widget under test inside a MaterialApp with the
/// required providers and theme.  The optional [size] can be used to
/// override the logical size of the view for tests that need a specific
/// screen size.
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
        home: Scaffold(body: const AdminDashboardView()),
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

  tearDown(() => container.dispose());

  /// Helper to prepare a dashboard snapshot with the given fields.
  Future<void> prepareDashboard(Map<String, Object?> fields) async {
    final dash = AdminItem(
      id: 'dashboard',
      kind: 'dashboard',
      seq: 1,
      removed: false,
      fields: fields,
    );
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [dash]),
      ],
    ];
    // keep provider alive
    container.listen(adminPanelsProvider, (_, _) {});
    await container.read(adminPanelsProvider.notifier).open('r');
    await container.read(adminPanelsProvider.notifier).refresh();
    expect(container.read(adminPanelsProvider).hasSnapshot, isTrue);
  }

  testWidgets('running-now rows show who and what they do', (tester) async {
    await prepareDashboard({
      'working': [
        {
          'kind': 'session',
          'who': 'Session A',
          'doing': 'Editing a file',
          'model': 'model-x',
          'secs': 30,
          'project': 'proj',
        },
        {
          'kind': 'worker',
          'who': 'coder worker',
          'doing': 'Write a parser',
          'model': 'model-y',
          'secs': 5,
          'project': 'proj',
        },
      ],
      'sessions': [],
      'stale': false,
    });

    await _pump(tester, container);
    expect(find.textContaining('Session A'), findsOneWidget);
    expect(find.textContaining('Editing a file'), findsOneWidget);
    expect(find.textContaining('coder worker'), findsOneWidget);
  });

  testWidgets('a long session name in tasks-left never breaks inside a word', (
    tester,
  ) async {
    await prepareDashboard({
      'working': [],
      'sessions': [
        {
          'name': 'Session Alpha (Coordinator)',
          'ctx': 120,
          'counts': {'running': 2, 'review': 4, 'blocked': 1, 'pending': 3},
          'rows': [],
          'todo': [],
        },
      ],
      'stale': false,
    });

    // set phone-sized screen
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await _pump(tester, container);
    final finder = find.text('Session Alpha (Coordinator)');
    expect(finder, findsNWidgets(2));

    for (var i = 0; i < 2; i++) {
      final p = tester.renderObject<RenderParagraph>(finder.at(i));
      for (final word in 'Session Alpha (Coordinator)'.split(' ')) {
        final tp = TextPainter(
          text: TextSpan(text: word, style: p.text.style),
          textDirection: TextDirection.ltr,
          textScaler: p.textScaler,
        )..layout();
        expect(
          p.size.width,
          greaterThanOrEqualTo(tp.width),
          reason:
              'word "$word" does not fit on one line, so it breaks mid-word',
        );
        tp.dispose();
      }
    }
  });

  testWidgets('tasks-left states are localized in Turkish', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [
        {
          'name': 'Session B',
          'ctx': 80,
          'counts': {'running': 2, 'review': 4, 'blocked': 1, 'pending': 3},
          'rows': [],
          'todo': [],
        },
      ],
      'stale': false,
    });

    await _pump(tester, container, locale: const Locale('tr'));
    expect(find.text('Session B'), findsWidgets);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join(' | ');

    for (final w in ['running', 'review', 'blocked', 'pending']) {
      expect(
        RegExp('\\b$w\\b', caseSensitive: false).hasMatch(texts),
        isFalse,
        reason: 'raw English state "$w" shown in Turkish UI: $texts',
      );
    }
    expect(texts, contains('4'));
  });
}
