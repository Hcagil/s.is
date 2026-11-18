import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
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

  Finder topicK(String t) => find.byKey(ValueKey('admin-question-topic-$t'));
  Finder subK(String t, String s) =>
      find.byKey(ValueKey('admin-question-sub-$t|$s'));
  Finder hdr(String id) => find.byKey(ValueKey('admin-question-header-$id'));

  AdminItem q(
    String id, {
    String topic = 'chat',
    String sub = '',
    bool waiting = false,
  }) {
    final fields = <String, Object?>{
      'id': id,
      'question': 'text $id',
      'answers': ['a', 'b'],
      'topic': topic,
      'sub': sub,
    };
    if (waiting) fields['state'] = 'waiting';
    return AdminItem(
      id: 'q:$id',
      kind: 'question',
      seq: 1,
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

  final List<AdminItem> F = [
    q('Q-1', topic: 'chat', sub: 'a'),
    q('Q-2', topic: 'chat', sub: 'b'),
    q('Q-5', topic: 'chat', sub: 'b'),
    q('Q-3', topic: 'tools'),
    q('Q-4', topic: 'tools'),
    q('Q-6', topic: 'tools'),
    q('Q-7', topic: 'tools'),
    q('Q-8', topic: 'tools', waiting: true),
  ];

  scene('1 open state', (tester) async {
    await load(tester, F);
    expect(topicK('chat'), findsOneWidget);
    expect(topicK('tools'), findsOneWidget);
    expect(subK('chat', 'a'), findsOneWidget);
    expect(subK('chat', 'b'), findsOneWidget);
    expect(hdr('Q-1'), findsOneWidget);
    expect(hdr('Q-2'), findsNothing);
    expect(hdr('Q-5'), findsNothing);
    expect(hdr('Q-3'), findsNothing);
    expect(hdr('Q-4'), findsNothing);
    expect(hdr('Q-8'), findsNothing);
  });

  scene('2 closed groups show count', (tester) async {
    await load(tester, F);
    expect(
      find.descendant(of: topicK('tools'), matching: find.text('4 to answer')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: subK('chat', 'b'),
        matching: find.text('2 to answer'),
      ),
      findsOneWidget,
    );
  });

  scene('3 tap topic toggles', (tester) async {
    await load(tester, F);
    await tester.tap(topicK('tools'));
    await tester.pumpAndSettle();
    expect(hdr('Q-3'), findsOneWidget);
    await tester.tap(topicK('tools'));
    await tester.pumpAndSettle();
    expect(hdr('Q-3'), findsNothing);
  });

  scene('4 tap sub toggles', (tester) async {
    await load(tester, F);
    await tester.tap(subK('chat', 'b'));
    await tester.pumpAndSettle();
    expect(hdr('Q-2'), findsOneWidget);
    expect(hdr('Q-5'), findsOneWidget);
    expect(hdr('Q-1'), findsOneWidget);
    await tester.tap(subK('chat', 'b'));
    await tester.pumpAndSettle();
    expect(hdr('Q-2'), findsNothing);
    expect(hdr('Q-1'), findsOneWidget);
  });

  scene('5 closing the open topic hides its questions', (tester) async {
    await load(tester, F);
    await tester.tap(topicK('chat'));
    await tester.pumpAndSettle();
    expect(hdr('Q-1'), findsNothing);
  });

  scene('6 empty sub sits directly under topic', (tester) async {
    await load(tester, F);
    await tester.tap(topicK('tools'));
    await tester.pumpAndSettle();
    expect(subK('tools', ''), findsNothing);
    expect(hdr('Q-3'), findsOneWidget);
    expect(subK('chat', ''), findsNothing);
  });

  scene('7 first unanswered decides what opens', (tester) async {
    await load(tester, [
      q('Q-1', topic: 'chat', sub: 'a', waiting: true),
      q('Q-2', topic: 'tools', sub: 'x'),
      q('Q-3', topic: 'chat', sub: 'a'),
    ]);
    expect(hdr('Q-2'), findsOneWidget);
    expect(subK('tools', 'x'), findsOneWidget);
    expect(hdr('Q-3'), findsNothing);
  });

  scene('8 unknown topic goes to other', (tester) async {
    await load(tester, [q('Q-1', topic: 'nonsense')]);
    expect(topicK('other'), findsOneWidget);
    expect(hdr('Q-1'), findsOneWidget);
  });
}
