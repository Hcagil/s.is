import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_questions_view.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../application/admin_fakes.dart';
import '../../../support/spy_admin_draft_store.dart';

late FakeAdminRepository repo;

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

ProviderContainer makeContainer(SpyAdminDraftStore spy) {
  return ProviderContainer(
    overrides: [
      adminPanelsRepositoryProvider.overrideWithValue(repo),
      adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
      adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
      adminDraftStoreProvider.overrideWithValue(spy),
    ],
  );
}

Future<ProviderContainer> boot(
  WidgetTester tester,
  SpyAdminDraftStore spy,
  List<AdminItem> items,
) async {
  final container = makeContainer(spy);
  container.listen(adminPanelsProvider, (_, _) {});
  final ctrl = container.read(adminPanelsProvider.notifier);
  repo.fetchQueue = [
    [snapRow(1, 1, cursor: 5, items: items)],
  ];
  await ctrl.open('reason');
  await ctrl.refresh();
  await _pump(tester, container);
  return container;
}

AdminItem textQ(String id) => AdminItem(
  id: 'q:$id',
  kind: 'question',
  seq: 1,
  removed: false,
  fields: {'id': id, 'question': 'text $id', 'kind': 'text'},
);

void main() {
  late ProviderContainer container;
  late SpyAdminDraftStore spy;

  setUp(() {
    repo = FakeAdminRepository();
    spy = SpyAdminDraftStore();
  });

  void scene(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
      container.dispose();
    });
  }

  scene('1 typing saves a draft after the debounce', (tester) async {
    container = await boot(tester, spy, [textQ('Q-1')]);
    final box = find.byKey(const ValueKey('admin-question-text-Q-1'));
    await tester.enterText(box, 'half an answer');
    await tester.pump(const Duration(milliseconds: 100));
    expect(spy.saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(spy.saved, {'q:Q-1': 'half an answer'});
  });

  scene('2 a saved draft is restored into the box', (tester) async {
    spy = SpyAdminDraftStore({'q:Q-1': 'saved answer'});
    container = await boot(tester, spy, [textQ('Q-1')]);
    await tester.pumpAndSettle();
    expect(find.text('saved answer'), findsOneWidget);
  });

  scene('3 a choice question restores into Other', (tester) async {
    spy = SpyAdminDraftStore({'q:Q-1': 'my own words'});
    container = await boot(tester, spy, [qItem('Q-1')]);
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('admin-question-text-Q-1'));
    expect(box, findsOneWidget);
    expect(find.text('my own words'), findsOneWidget);
  });

  scene('4 leaving and coming back restores', (tester) async {
    container = await boot(tester, spy, [textQ('Q-1')]);
    final box = find.byKey(const ValueKey('admin-question-text-Q-1'));
    await tester.enterText(box, 'left half');
    // Leave the view without waiting for the debounce.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
    expect(spy.saved, {'q:Q-1': 'left half'});
    // Come back: the same app state, a new view.
    await _pump(tester, container);
    expect(find.text('left half'), findsOneWidget);
  });

  scene('5 a successful send clears the draft', (tester) async {
    spy = SpyAdminDraftStore({'q:Q-1': 'will send'});
    container = await boot(tester, spy, [textQ('Q-1')]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();
    expect(repo.sent, hasLength(1));
    expect(spy.saved, isEmpty);
  });

  scene('6 a failed send keeps the draft', (tester) async {
    spy = SpyAdminDraftStore({'q:Q-1': 'will send'});
    container = await boot(tester, spy, [textQ('Q-1')]);
    await tester.pumpAndSettle();
    repo.sendResult = const Err(NetworkFailure('x'));
    await tester.tap(find.byKey(const ValueKey('admin-send')));
    await tester.pumpAndSettle();
    expect(spy.saved, {'q:Q-1': 'will send'});
    expect(find.text('will send'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  scene('7 the box is capped at 8192 characters', (tester) async {
    container = await boot(tester, spy, [textQ('Q-1')]);
    final box = find.byKey(const ValueKey('admin-question-text-Q-1'));
    final long = 'x' * 9000;
    await tester.enterText(box, long);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    final tf = tester.widget<TextField>(box);
    expect(tf.controller!.text.length, 8192);
    expect(spy.saved['q:Q-1']!.length, 8192);
  });

  scene('8 blank text removes the draft', (tester) async {
    spy = SpyAdminDraftStore({'q:Q-1': 'old'});
    container = await boot(tester, spy, [textQ('Q-1')]);
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('admin-question-text-Q-1'));
    await tester.enterText(box, '   ');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(spy.saved, isEmpty);
  });
}
