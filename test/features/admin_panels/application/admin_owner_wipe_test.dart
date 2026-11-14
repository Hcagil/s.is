// test/features/admin_panels/application/admin_owner_wipe_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_owner_wipe.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';

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
}) async {
  _Session.initial = initial;
  final c = ProviderContainer.test(
    overrides: [
      sessionControllerProvider.overrideWith(_Session.new),
      adminPanelsRepositoryProvider.overrideWithValue(repo),
      adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
      adminSnapshotStoreProvider.overrideWithValue(snap),
      adminSeenStoreProvider.overrideWithValue(seen),
    ],
  );
  // Listen to the wipe provider to trigger it.
  c.listen(adminOwnerWipeProvider, (_, _) {});
  // Wait for the session controller to finish building.
  await c.read(sessionControllerProvider.future);
  await pumpEventQueue();
  return c;
}

/// Repository that throws on forget.
class _ThrowingForgetRepo extends FakeAdminRepository {
  @override
  Future<void> forget() async {
    forgetCalls++;
    throw StateError('boom');
  }
}

void main() {
  group('adminOwnerWipeProvider', () {
    late ProviderContainer c;
    late FakeAdminRepository repo;
    late FakeAdminSnapshotStore snap;
    late FakeAdminSeenStore seen;

    setUp(() async {
      repo = FakeAdminRepository();
      snap = FakeAdminSnapshotStore();
      seen = FakeAdminSeenStore();
    });

    test('wipes on SignedOut', () async {
      c = await scope(const Allowed(me), repo: repo, snap: snap, seen: seen);
      // Emit SignedOut to trigger wipe
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const SignedOut(),
      );
      await pumpEventQueue();
      expect(repo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });

    test('wipes on Denied', () async {
      c = await scope(const Allowed(me), repo: repo, snap: snap, seen: seen);
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Denied(),
      );
      await pumpEventQueue();
      expect(repo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });

    test('wipes on Removed', () async {
      c = await scope(const Allowed(me), repo: repo, snap: snap, seen: seen);
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Removed(),
      );
      await pumpEventQueue();
      expect(repo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });

    test('wipes on Replaced', () async {
      c = await scope(const Allowed(me), repo: repo, snap: snap, seen: seen);
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Replaced(),
      );
      await pumpEventQueue();
      expect(repo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });

    test('initial SignedOut triggers wipe immediately', () async {
      c = await scope(const SignedOut(), repo: repo, snap: snap, seen: seen);
      expect(repo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });

    test('Allowed does nothing', () async {
      c = await scope(const Allowed(me), repo: repo, snap: snap, seen: seen);
      expect(repo.forgetCalls, 0);
      expect(snap.clearCalls, 0);
      expect(seen.clearCalls, 0);
      // Emit a different Allowed
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const Allowed(Member(userId: 'u2', displayName: 'Ana')),
      );
      await pumpEventQueue();
      expect(repo.forgetCalls, 0);
      expect(snap.clearCalls, 0);
      expect(seen.clearCalls, 0);
    });

    test('throwing forget does not stop clears', () async {
      final throwingRepo = _ThrowingForgetRepo();
      c = await scope(
        const Allowed(me),
        repo: throwingRepo,
        snap: snap,
        seen: seen,
      );
      // Emit SignedOut to trigger wipe
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const SignedOut(),
      );
      await pumpEventQueue();
      expect(throwingRepo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });

    test('live panels state is locked and cleared', () async {
      repo.fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
      c = await scope(const Allowed(me), repo: repo, snap: snap, seen: seen);
      // Open a panel to create a live state
      c.listen(adminPanelsProvider, (_, _) {});
      await c.read(adminPanelsProvider.notifier).open('reason');
      // Wait until the panel has a snapshot
      for (var i = 0; i < 10; i++) {
        await pumpEventQueue();
        if (c.read(adminPanelsProvider).hasSnapshot) break;
      }
      expect(c.read(adminPanelsProvider).hasSnapshot, true);
      expect(c.read(adminPanelsProvider).snapshot.questions.length, 1);
      // Emit SignedOut to trigger wipe
      (c.read(sessionControllerProvider.notifier) as _Session).emit(
        const SignedOut(),
      );
      await pumpEventQueue();
      expect(c.read(adminPanelsProvider).hasSnapshot, false);
      expect(c.read(adminPanelsProvider).snapshot.questions.isEmpty, true);
      expect(c.read(adminPanelsProvider).gate, AdminGate.checking);
    });

    test('seen store wiped on sign-out', () async {
      seen.saved = {
        'talk': {'a'},
      };
      c = await scope(const SignedOut(), repo: repo, snap: snap, seen: seen);
      expect(seen.saved, null);
      expect(seen.clearCalls, 1);
    });

    test('wipes when the session is already SignedOut before the wipe provider starts', () async {
      // Create overrides and container first
      _Session.initial = const SignedOut();
      final c = ProviderContainer.test(
        overrides: [
          sessionControllerProvider.overrideWith(_Session.new),
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
          adminSnapshotStoreProvider.overrideWithValue(snap),
          adminSeenStoreProvider.overrideWithValue(seen),
        ],
      );
      // Wait for session controller to finish building
      await c.read(sessionControllerProvider.future);
      await pumpEventQueue();
      // Now listen to the wipe provider
      c.listen(adminOwnerWipeProvider, (_, _) {});
      await pumpEventQueue();
      expect(repo.forgetCalls, 1);
      expect(snap.clearCalls, 1);
      expect(seen.clearCalls, 1);
    });
  });
}
