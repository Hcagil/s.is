import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
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

  testWidgets('three usage rows with the section title', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      'usage': {
        'rateLimits': [
          {
            'kind': 'five_hour',
            'percentUsed': 42,
            'resetsAt': '2026-11-15T14:30:00Z',
          },
          {
            'kind': 'seven_day',
            'percentUsed': 10,
            'resetsAt': '2026-11-20T10:00:00Z',
          },
          {
            'kind': 'spend_limit',
            'percentUsed': 5,
            'resetsAt': '2026-12-01T00:00:00Z',
          },
        ],
      },
    });

    await _pump(tester, container);

    expect(find.text('AI usage limits'), findsOneWidget);

    final fiveKey = const ValueKey('admin-dash-usage-five_hour');
    final sevenKey = const ValueKey('admin-dash-usage-seven_day');
    final spendKey = const ValueKey('admin-dash-usage-spend_limit');

    expect(find.byKey(fiveKey), findsOneWidget);
    expect(find.byKey(sevenKey), findsOneWidget);
    expect(find.byKey(spendKey), findsOneWidget);

    final fiveReset = DateFormat.Hm('en')
        .format(DateTime.parse('2026-11-15T14:30:00Z').toLocal());
    final sevenReset = DateFormat.MMMd('en')
        .format(DateTime.parse('2026-11-20T10:00:00Z').toLocal());
    final spendReset = DateFormat.MMMd('en')
        .format(DateTime.parse('2026-12-01T00:00:00Z').toLocal());

    expect(
      find.descendant(
        of: find.byKey(fiveKey),
        matching: find.text('42% used · resets $fiveReset'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(sevenKey),
        matching: find.text('10% used · resets $sevenReset'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(spendKey),
        matching: find.text('5% used · resets $spendReset'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the section sits above Context', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [
        {
          'name': 'Session Alpha',
          'ctx': 120,
          'counts': {'running': 1, 'review': 0, 'blocked': 0, 'pending': 0},
          'rows': [],
          'todo': [],
        },
      ],
      'stale': false,
      'usage': {
        'rateLimits': [
          {
            'kind': 'five_hour',
            'percentUsed': 42,
            'resetsAt': '2026-11-15T14:30:00Z',
          },
        ],
      },
    });

    await _pump(tester, container);

    final sectionDy = tester.getTopLeft(find.text('AI usage limits')).dy;
    final sessionDy = tester.getTopLeft(find.text('Context size')).dy;
    expect(sectionDy, lessThan(sessionDy));
  });

  testWidgets('red at 90, not at 89', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      'usage': {
        'rateLimits': [
          {
            'kind': 'five_hour',
            'percentUsed': 90,
            'resetsAt': '2026-11-15T14:30:00Z',
          },
          {
            'kind': 'seven_day',
            'percentUsed': 89,
            'resetsAt': '2026-11-20T10:00:00Z',
          },
        ],
      },
    });

    await _pump(tester, container);

    final fiveIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('admin-dash-usage-five_hour')),
        matching: find.byIcon(Icons.speed_outlined),
      ),
    );
    final sevenIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('admin-dash-usage-seven_day')),
        matching: find.byIcon(Icons.speed_outlined),
      ),
    );

    expect(fiveIcon.color, equals(SisBrand.light.danger));
    expect(sevenIcon.color, isNot(equals(SisBrand.light.danger)));
  });

  testWidgets('unknown kinds are skipped', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      'usage': {
        'rateLimits': [
          {
            'kind': 'monthly_x',
            'percentUsed': 50,
            'resetsAt': '2026-11-20T10:00:00Z',
          },
          {
            'kind': 'five_hour',
            'percentUsed': 42,
            'resetsAt': '2026-11-15T14:30:00Z',
          },
        ],
      },
    });

    await _pump(tester, container);

    expect(
      find.byKey(const ValueKey('admin-dash-usage-monthly_x')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-dash-usage-five_hour')),
      findsOneWidget,
    );
  });

  testWidgets('a missing or unparsable reset time shows a dash', (
    tester,
  ) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      'usage': {
        'rateLimits': [
          {
            'kind': 'five_hour',
            'percentUsed': 42,
            // no resetsAt
          },
          {'kind': 'seven_day', 'percentUsed': 10, 'resetsAt': 'not a date'},
        ],
      },
    });

    await _pump(tester, container);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-dash-usage-five_hour')),
        matching: find.text('42% used · resets -'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-dash-usage-seven_day')),
        matching: find.text('10% used · resets -'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('bad entries are skipped and the rest shows', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      'usage': {
        'rateLimits': [
          'junk',
          7,
          {'kind': 'five_hour'},
          {'kind': 'seven_day', 'percentUsed': 'abc'},
          {
            'kind': 'spend_limit',
            'percentUsed': 5,
            'resetsAt': '2026-12-01T00:00:00Z',
          },
        ],
      },
    });

    await _pump(tester, container);

    expect(
      find.byKey(const ValueKey('admin-dash-usage-spend_limit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-dash-usage-five_hour')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-dash-usage-seven_day')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage alone replaces the empty text', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      'usage': {
        'rateLimits': [
          {
            'kind': 'five_hour',
            'percentUsed': 42,
            'resetsAt': '2026-11-15T14:30:00Z',
          },
        ],
      },
    });

    await _pump(tester, container);

    expect(find.text('Nothing open'), findsNothing);
    expect(find.text('AI usage limits'), findsOneWidget);
  });

  testWidgets('no usage, no work: the empty text shows', (tester) async {
    await prepareDashboard({
      'working': [],
      'sessions': [],
      'stale': false,
      // no usage field
    });

    await _pump(tester, container);

    expect(find.text('Nothing open'), findsOneWidget);
    expect(find.text('AI usage limits'), findsNothing);
  });
}
