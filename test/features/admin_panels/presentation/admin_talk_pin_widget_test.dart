import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/core/failure.dart';

import '../application/admin_fakes.dart';

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
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('base-open'),
                onPressed: () => showAdminPanels(ctx),
                child: const Text('Base'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // open the Admin Panels route
  await tester.tap(find.byKey(const ValueKey('base-open')));
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
  AdminItem convItem({int pinnedAt = 0}) => AdminItem(
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
      if (pinnedAt > 0) 'pinned_at': pinnedAt,
    },
  );

  /// Finder for the conversation tile.
  Finder tile = find.byKey(const ValueKey('admin-conv-tile-c1'));

  /// Finder for the pin menu item.
  Finder pinMenuItem = find.byKey(const ValueKey('admin-conv-pin-c1'));

  /// Finder for the pin mark.
  Finder pinMark = find.byKey(const ValueKey('admin-conv-pinmark-c1'));

  /// Prepare initial snapshot with the given items.
  Future<void> prepareInitial(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
  }

  /// Helper to open the Talk list.
  Future<void> openTalk(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text('Talk'),
      ),
    );
    await tester.pumpAndSettle();
  }

  scene(
    'long press shows Pin; tapping it sends a pin note and shows the mark at once',
    (tester) async {
      await prepareInitial([convItem()]);
      await _pump(tester, container);
      await openTalk(tester);
      expect(pinMark, findsNothing);
      await tester.longPress(tile);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: pinMenuItem, matching: find.text('Pin')),
        findsOneWidget,
      );
      await tester.tap(pinMenuItem);
      await tester.pumpAndSettle();
      expect(repo.sent.length, 1);
      final sent = repo.sent.first;
      expect(sent['kind'], 'pin');
      expect(sent['conv'], 'c1');
      expect(sent['pinned'], true);
      expect(sent.containsKey('answer_id'), true);
      expect(pinMark, findsOneWidget);
    },
  );

  scene(
    'a pinned conversation shows Unpin; tapping it sends pinned false and removes the mark',
    (tester) async {
      await prepareInitial([convItem(pinnedAt: 100)]);
      await _pump(tester, container);
      await openTalk(tester);
      expect(pinMark, findsOneWidget);
      await tester.longPress(tile);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: pinMenuItem, matching: find.text('Unpin')),
        findsOneWidget,
      );
      await tester.tap(pinMenuItem);
      await tester.pumpAndSettle();
      expect(repo.sent.last['pinned'], false);
      expect(pinMark, findsNothing);
    },
  );

  scene('send failure shows the notice and the mark goes back', (tester) async {
    repo.sendResult = Err<AdminSentRef?>(const NetworkFailure('x'));
    await prepareInitial([convItem()]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    await tester.tap(pinMenuItem);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Could not pin. Try again.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(pinMark, findsNothing);
  });

  scene('unpin failure shows the notice and the mark stays', (tester) async {
    repo.sendResult = Err<AdminSentRef?>(const NetworkFailure('x'));
    await prepareInitial([convItem(pinnedAt: 100)]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    await tester.tap(pinMenuItem);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Could not unpin. Try again.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(pinMark, findsOneWidget);
  });

  scene('computer rejection: mark goes back and no notice', (tester) async {
    await prepareInitial([convItem()]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    await tester.tap(pinMenuItem);
    await tester.pumpAndSettle();
    // simulate rejection
    repo.fetchQueue = [
      [
        deltaRow(
          2,
          2,
          cursor: 7,
          results: [AdminAnswerResult(epoch: 1, upSeq: 1, ok: false)],
        ),
      ],
    ];
    await container.read(adminPanelsProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(pinMark, findsNothing);
    expect(find.text('Could not pin. Try again.'), findsNothing);
  });

  scene('the mark carries the semantic label Pinned', (tester) async {
    await prepareInitial([convItem(pinnedAt: 100)]);
    await _pump(tester, container);
    await openTalk(tester);
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('Pinned')), findsOneWidget);
    handle.dispose();
  });
}
