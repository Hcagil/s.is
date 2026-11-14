// test/features/admin_panels/application/admin_drafts_wipe_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_owner_wipe.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';

import '../../../support/spy_admin_draft_store.dart';
import './admin_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

/// Session controller used in tests.
/// Keeps a static initial value that can be set before each test.
class _Session extends SessionController {
  static SessionState initial = const SignedOut();

  @override
  Future<SessionState> build() async => initial;

  /// Emit a new session state.
  void emit(SessionState s) => state = AsyncData(s);
}

/// Helper that builds a ProviderContainer with the required overrides
/// and returns the container together with the fake objects used.
Future<ProviderContainer> scope(
  SessionState initial, {
  required FakeAdminRepository repo,
  required FakeAdminSnapshotStore snap,
  required FakeAdminSeenStore seen,
  required SpyAdminDraftStore draftStore,
}) async {
  _Session.initial = initial;
  final c = ProviderContainer.test(
    overrides: [
      sessionControllerProvider.overrideWith(_Session.new),
      adminPanelsRepositoryProvider.overrideWithValue(repo),
      adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
      adminSnapshotStoreProvider.overrideWithValue(snap),
      adminSeenStoreProvider.overrideWithValue(seen),
      adminDraftStoreProvider.overrideWithValue(draftStore),
    ],
  );
  // Listen to the wipe provider to trigger it.
  c.listen(adminOwnerWipeProvider, (_, _) {});
  // Wait for the session controller to finish building.
  await c.read(sessionControllerProvider.future);
  await pumpEventQueue();
  return c;
}

void main() {
  group('adminOwnerWipeProvider (drafts)', () {
    late ProviderContainer c;
    late FakeAdminRepository repo;
    late FakeAdminSnapshotStore snap;
    late FakeAdminSeenStore seen;

    setUp(() async {
      repo = FakeAdminRepository();
      snap = FakeAdminSnapshotStore();
      seen = FakeAdminSeenStore();
    });

    test('SignedOut wipes drafts', () async {
      final spy = SpyAdminDraftStore({
        'q:Q-1': 'half typed',
        'talk:new': 'hello',
      });
      c = await scope(
        const Allowed(me),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      // Load drafts to populate in‑memory copy
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), 'half typed');
      // Emit SignedOut to trigger wipe
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const SignedOut(),
      );
      await pumpEventQueue();
      expect(spy.clears, 1);
      expect(spy.saves, 0);
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), '');
    });

    test('Denied wipes drafts', () async {
      final spy = SpyAdminDraftStore({
        'q:Q-1': 'half typed',
        'talk:new': 'hello',
      });
      c = await scope(
        const Allowed(me),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), 'half typed');
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Denied(),
      );
      await pumpEventQueue();
      expect(spy.clears, 1);
      expect(spy.saves, 0);
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), '');
    });

    test('Replaced wipes drafts', () async {
      final spy = SpyAdminDraftStore({
        'q:Q-1': 'half typed',
        'talk:new': 'hello',
      });
      c = await scope(
        const Allowed(me),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), 'half typed');
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Replaced(),
      );
      await pumpEventQueue();
      expect(spy.clears, 1);
      expect(spy.saves, 0);
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), '');
    });

    test('Allowed does not wipe', () async {
      final spy = SpyAdminDraftStore({
        'q:Q-1': 'half typed',
        'talk:new': 'hello',
      });
      c = await scope(
        const Allowed(me),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), 'half typed');
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Allowed(Member(userId: 'u2', displayName: 'Ana')),
      );
      await pumpEventQueue();
      expect(spy.clears, 0);
      expect(spy.saves, 0);
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), 'half typed');
    });

    test('a pending (unflushed) draft is not written after sign-out', () async {
      final spy = SpyAdminDraftStore();
      c = await scope(
        const Allowed(me),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      // Start a debounce write
      await c.read(adminDraftsProvider).write('q:Q-2', 'typed');
      // Emit SignedOut before debounce fires
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const SignedOut(),
      );
      await pumpEventQueue();
      // Wait longer than debounce period
      await Future.delayed(const Duration(milliseconds: 700));
      expect(spy.saves, 0);
      expect(spy.saved.isEmpty, true);
    });

    test('sign-out with the panels open leaves no draft behind', () async {
      final spy = SpyAdminDraftStore();
      c = await scope(
        const Allowed(me),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      c.listen(adminPanelsProvider, (_, _) {});
      await c.read(adminDraftsProvider).write('q:Q-1', 'typed');
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const SignedOut(),
      );
      await pumpEventQueue();
      await Future.delayed(const Duration(milliseconds: 700));
      expect(spy.saved, isEmpty);
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), '');
    });

    test('initial SignedOut wipes at start', () async {
      final spy = SpyAdminDraftStore({
        'q:Q-1': 'half typed',
        'talk:new': 'hello',
      });
      c = await scope(
        const SignedOut(),
        repo: repo,
        snap: snap,
        seen: seen,
        draftStore: spy,
      );
      expect(spy.clears, 1);
      expect(spy.saves, 0);
      expect(await c.read(adminDraftsProvider).read('q:Q-1'), '');
    });
  });
}
