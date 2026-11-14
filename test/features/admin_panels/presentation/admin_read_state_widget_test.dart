import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/l10n/app_localizations.dart';

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
  AdminItem convItem({int? seen, int? mat, bool unread = false}) => AdminItem(
    id: 'c:c1',
    kind: 'talk',
    seq: 1,
    removed: false,
    fields: {
      'id': 'c1',
      'topic': 'Topic',
      'at': 1000,
      'unread': unread,
      'waiting': 0,
      'conv': true,
      'seen': ?(mat == null ? null : (seen ?? 0)),
      'mat': ?mat,
    },
  );

  /// Finder for the conversation tile.
  Finder tile = find.byKey(const ValueKey('admin-conv-tile-c1'));

  /// Helper to check unread icon presence.
  bool unreadIcon() => find
      .descendant(
        of: tile,
        matching: find.byIcon(Icons.mark_chat_unread_outlined),
      )
      .evaluate()
      .isNotEmpty;

  /// Helper to check read icon presence.
  bool readIcon() => find
      .descendant(
        of: tile,
        matching: find.byIcon(Icons.chat_bubble_outline_rounded),
      )
      .evaluate()
      .isNotEmpty;

  /// Helper to push a new snapshot state.
  Future<void> push(WidgetTester tester, AdminItem item, int n) async {
    repo.fetchQueue.add([
      deltaRow(n, n, cursor: 5 + n, items: [item]),
    ]);
    await container.read(adminPanelsProvider.notifier).refresh();
    await tester.pumpAndSettle();
  }

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
    'tapping a unread conversation sends one read note and shows it read at once',
    (tester) async {
      await prepareInitial([convItem(mat: 20)]);
      await _pump(tester, container);
      await openTalk(tester);
      expect(unreadIcon(), true);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(repo.sent.length, 1);
      final sent = repo.sent.first;
      expect(sent['kind'], 'read');
      expect(sent['conv'], 'c1');
      expect(sent['upto'], 20);
      expect(sent.containsKey('id'), false);
      expect(sent.containsKey('text'), false);
      await tester.tap(find.byKey(const ValueKey('admin-talk-back')));
      await tester.pumpAndSettle();
      expect(readIcon(), true);
      expect(unreadIcon(), false);
    },
  );

  scene(
    'old computer: opening does not clear the unread mark and sends nothing',
    (tester) async {
      await prepareInitial([convItem(unread: true)]);
      await _pump(tester, container);
      await openTalk(tester);
      expect(unreadIcon(), true);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-talk-back')));
      await tester.pumpAndSettle();
      expect(unreadIcon(), true);
      expect(repo.sent.isEmpty, true);
    },
  );

  scene('a conversation the computer already shows read sends nothing', (
    tester,
  ) async {
    await prepareInitial([convItem(seen: 20, mat: 20)]);
    await _pump(tester, container);
    await openTalk(tester);
    expect(readIcon(), true);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(repo.sent.isEmpty, true);
    await tester.tap(find.byKey(const ValueKey('admin-talk-back')));
    await tester.pumpAndSettle();
    expect(readIcon(), true);
  });

  scene(
    'while open, a larger mat sends again; the same mat again sends nothing',
    (tester) async {
      await prepareInitial([convItem(mat: 20)]);
      await _pump(tester, container);
      await openTalk(tester);
      await tester.tap(tile);
      expect(repo.sent.length, 1);
      await push(tester, convItem(mat: 40), 2);
      expect(repo.sent.length, 2);
      expect(repo.sent.last['upto'], 40);
      await push(tester, convItem(mat: 40), 3);
      await tester.pump();
      await tester.pump();
      expect(repo.sent.length, 2);
    },
  );

  scene('a new manager message while closed shows unread again', (
    tester,
  ) async {
    await prepareInitial([convItem(mat: 20)]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-talk-back')));
    await tester.pumpAndSettle();
    expect(readIcon(), true);
    await push(tester, convItem(mat: 50), 2);
    expect(unreadIcon(), true);
    expect(repo.sent.length, 1);
  });

  scene('read on the computer shows read with no up message', (tester) async {
    await prepareInitial([convItem(mat: 20)]);
    await _pump(tester, container);
    await openTalk(tester);
    expect(unreadIcon(), true);
    await push(tester, convItem(seen: 20, mat: 20), 2);
    expect(readIcon(), true);
    expect(repo.sent.isEmpty, true);
  });

  scene('no waiting card after a read note', (tester) async {
    await prepareInitial([convItem(mat: 20)]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.tap(tile);
    expect(container.read(adminPanelsProvider).answers.isEmpty, true);
  });
}
