import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/presentation/admin_talk_composer.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../../support/spy_admin_draft_store.dart';
import '../application/admin_fakes.dart';

late FakeAdminRepository repo;

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer c, {
  String? conv,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AdminTalkComposer(conv: conv),
          ),
        ),
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

  scene('1 typing in a conversation saves talk:c1 after the debounce', (
    tester,
  ) async {
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    final box = find.byKey(const ValueKey('admin-talk-input'));
    await tester.enterText(box, 'hello there');
    await tester.pump(const Duration(milliseconds: 100));
    expect(spy.saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(spy.saved, {'talk:c1': 'hello there'});
  });

  scene('2 the box with no conversation saves talk:new', (tester) async {
    container = makeContainer(spy);
    await _mount(tester, container);
    final box = find.byKey(const ValueKey('admin-talk-input'));
    await tester.enterText(box, 'a new topic');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(spy.saved, {'talk:new': 'a new topic'});
  });

  scene('3 a saved draft is restored on mount', (tester) async {
    spy = SpyAdminDraftStore({'talk:c1': 'unsent words'});
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    expect(find.text('unsent words'), findsOneWidget);
  });

  scene('4 another conversation does not show it', (tester) async {
    spy = SpyAdminDraftStore({'talk:c1': 'unsent words'});
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c2');
    expect(find.text('unsent words'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
    await _mount(tester, container);
    expect(find.text('unsent words'), findsNothing);
  });

  scene('5 losing focus saves at once', (tester) async {
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    final box = find.byKey(const ValueKey('admin-talk-input'));
    await tester.tap(box);
    await tester.enterText(box, 'focus text');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 50));
    expect(spy.saved, {'talk:c1': 'focus text'});
  });

  scene('6 leaving the box saves at once', (tester) async {
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    final box = find.byKey(const ValueKey('admin-talk-input'));
    await tester.enterText(box, 'left behind');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
    expect(spy.saved, {'talk:c1': 'left behind'});
  });

  scene('7 a successful send clears field and draft', (tester) async {
    spy = SpyAdminDraftStore({'talk:c1': 'to send'});
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    final sendBtn = find.byKey(const ValueKey('admin-talk-send'));
    await tester.tap(sendBtn);
    await tester.pumpAndSettle();
    expect(repo.sent, hasLength(1));
    expect(repo.sent.single['text'], 'to send');
    expect(find.text('to send'), findsNothing);
    expect(spy.saved, isEmpty);
  });

  scene('8 a failed send keeps field and draft', (tester) async {
    spy = SpyAdminDraftStore({'talk:c1': 'to send'});
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    repo.sendResult = const Err(NetworkFailure('x'));
    final sendBtn = find.byKey(const ValueKey('admin-talk-send'));
    await tester.tap(sendBtn);
    await tester.pumpAndSettle();
    expect(find.text('to send'), findsOneWidget);
    expect(spy.saved, {'talk:c1': 'to send'});
    await tester.pump(const Duration(seconds: 3));
  });

  scene('9 capped at 8192 characters', (tester) async {
    container = makeContainer(spy);
    await _mount(tester, container, conv: 'c1');
    final box = find.byKey(const ValueKey('admin-talk-input'));
    final long = 'y' * 9000;
    await tester.enterText(box, long);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    final tf = tester.widget<TextField>(box);
    expect(tf.controller!.text.length, 8192);
    expect(spy.saved['talk:c1']!.length, 8192);
  });
}
