// KeyDirectoryController when the phone storage keeps failing the pickle-key
// read (PickleKeyStore.loadOrCreate throws). Wired through the same
// providers main.dart overrides; the directory, engine and pickle store are
// the shared fakes (test/support/key_directory_fakes.dart); the pickle-key
// store is this file's own, throwing on demand.
// Contract: Retrying for failures 1-4, StorageStuck from the 5th; the retries
// go on (delay capped at 60 s); the pickles are never read and no key is
// created or deleted; a success resets the count; a late failure of an old
// run changes nothing. Written from the contract.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import '../../support/container_end.dart';
import '../../support/key_directory_fakes.dart';

const _allowed = Allowed(Member(userId: 'u1', displayName: 'Maya'));

class _FlakyPickleKeys implements PickleKeyStore {
  bool fail = true;
  int calls = 0;
  int deletes = 0;

  /// When set, the next call waits for it (and then fails or answers).
  Completer<void>? hold;

  @override
  Future<List<int>> loadOrCreate() async {
    calls++;
    final h = hold;
    hold = null;
    await Future<void>.delayed(Duration.zero);
    if (h != null) await h.future;
    if (fail) {
      throw PlatformException(code: 'Exception', message: 'Keystore');
    }
    return List.of(FakePickleKeys.key);
  }

  @override
  Future<void> delete() async => deletes++;
}

class _CountingPickles extends FakePickleStore {
  _CountingPickles(super.log);
  int loads = 0;
  int updates = 0;

  @override
  Future<String?> load() {
    loads++;
    return super.load();
  }

  @override
  Future<bool> update(Future<String?> Function(String? current) change) {
    updates++;
    return super.update(change);
  }
}

class _Rig {
  final KeyLog log = [];
  late final dir = FakeKeyDirectory(log);
  late final engine = FakeEngine(log);
  late final pickles = _CountingPickles(log);
  final keys = _FlakyPickleKeys();
  late final ProviderContainer c;
  late final DrivenSession session;

  KeyDirectoryState get state => c.read(keyDirectoryControllerProvider);

  Future<void> start(WidgetTester t) async {
    c = track(
      ProviderContainer(
        overrides: [
          sessionControllerProvider.overrideWith(
            () => session = DrivenSession(_allowed),
          ),
          keyDirectoryProvider.overrideWithValue(dir),
          keyEngineProvider.overrideWithValue(engine),
          olmPickleStoreProvider.overrideWithValue(pickles),
          pickleKeyStoreProvider.overrideWithValue(keys),
        ],
      ),
    );
    c.listen(keyDirectoryControllerProvider, (_, _) {});
    await settle(t);
  }

  void nothingTouched() {
    expect(pickles.loads, 0, reason: 'the pickles are never read');
    expect(pickles.updates, 0, reason: 'no pickle transaction either');
    expect(engine.created, 0, reason: 'no new account');
    expect(dir.publishes, isEmpty);
    expect(keys.deletes, 0, reason: 'no key deleted');
  }
}

/// Lets every async hop run (the fake key store answers after a zero-delay
/// timer, as a platform call does), without moving the clock.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(Duration.zero);
  }
}

/// Moves the clock exactly to the next retry (the ladder delay, capped 60 s);
/// the clock never runs ahead, so the next retry is due exactly one delay on.
Future<void> nextRetry(WidgetTester t, int failuresSoFar) async {
  final i = failuresSoFar - 1;
  final d = i < sessionRetryDelays.length
      ? sessionRetryDelays[i]
      : sessionRetryDelays.last;
  await t.pump(d);
  await settle(t);
}

void main() {
  testWidgets('fixture: the ladder the controller retries on is capped at '
      '60 s', (t) async {
    expect(sessionRetryDelays.last, const Duration(seconds: 60));
  });

  testWidgets('failures 1-4 Retrying, from the 5th StorageStuck; retries go '
      'on every 60 s; nothing read, created or deleted', (t) async {
    final r = _Rig();
    await r.start(t);
    expect(r.keys.calls, 1);
    expect(r.state, isA<KeysRetrying>(), reason: 'failure 1');

    for (var n = 2; n <= 4; n++) {
      await nextRetry(t, n - 1);
      expect(r.keys.calls, n, reason: 'retry $n ran on the timer');
      expect(r.state, isA<KeysRetrying>(), reason: 'failure $n');
    }
    await nextRetry(t, 4);
    expect(r.keys.calls, 5);
    expect(r.state, isA<KeysStorageStuck>(), reason: 'failure 5');

    // Stuck still retries: on the ladder (32 s), then never longer than 60 s.
    await nextRetry(t, 5);
    expect(r.keys.calls, 6);
    expect(r.state, isA<KeysStorageStuck>(), reason: 'failure 6');
    for (var n = 7; n <= 9; n++) {
      await t.pump(
        const Duration(seconds: 60) - const Duration(milliseconds: 100),
      );
      await settle(t);
      final before = r.keys.calls;
      expect(before, n - 1, reason: 'retry $n not before 60 s');
      await t.pump(const Duration(milliseconds: 100));
      await settle(t);
      expect(r.keys.calls, n, reason: 'retry $n at 60 s, not later');
      expect(r.state, isA<KeysStorageStuck>(), reason: 'failure $n');
    }
    r.nothingTouched();
  });

  testWidgets('a later success resets the count: the next failing series '
      'again needs 5 for StorageStuck', (t) async {
    final r = _Rig();
    await r.start(t);
    for (var n = 2; n <= 6; n++) {
      await nextRetry(t, n - 1);
    }
    expect(r.state, isA<KeysStorageStuck>());
    r.nothingTouched();

    // The storage works again: the next retry gets the key and goes on.
    r.keys.fail = false;
    await nextRetry(t, 6);
    expect(r.state, isA<KeysReady>());
    expect(r.engine.created, 1);

    // A new failing series.
    r.keys.fail = true;
    final calls = r.keys.calls;
    // Not awaited directly: its hops need the fake clock pumped.
    unawaited(r.c.read(keyDirectoryControllerProvider.notifier).refresh());
    await settle(t);
    expect(r.keys.calls, calls + 1, reason: 'fixture: refresh read the key');
    expect(r.state, isA<KeysRetrying>(), reason: 'failure 1 of the series');
    for (var n = 2; n <= 4; n++) {
      await nextRetry(t, n - 1);
      expect(r.keys.calls, calls + n);
      expect(r.state, isA<KeysRetrying>(), reason: 'failure $n of the series');
    }
    await nextRetry(t, 4);
    expect(r.state, isA<KeysStorageStuck>(), reason: 'failure 5 of series');
    expect(r.keys.deletes, 0);
  });

  testWidgets('a late failure of an old run (signed out meanwhile) changes '
      'nothing', (t) async {
    final r = _Rig();
    await r.start(t);
    for (var n = 2; n <= 4; n++) {
      await nextRetry(t, n - 1);
    }
    expect(r.state, isA<KeysRetrying>());
    expect(r.keys.calls, 4);

    // The 5th read hangs; the member signs out before it fails.
    final h = r.keys.hold = Completer<void>();
    await nextRetry(t, 4);
    expect(r.keys.calls, 5, reason: 'fixture: the 5th read started');
    r.session.set(const SignedOut());
    await settle(t);
    expect(r.state, isA<KeysIdle>());
    h.complete();
    await settle(t);
    expect(r.state, isA<KeysIdle>(), reason: 'the old failure is ignored');

    await t.pump(const Duration(seconds: 130));
    await settle(t);
    expect(r.keys.calls, 5, reason: 'no retry scheduled by the old run');
    expect(r.state, isA<KeysIdle>());
    r.nothingTouched();
  });
}
