// The cold-start marker on a real disk (0.30.15/0.30.16): SessionController
// over the real FileLastSessionStore in a temp directory, auth faked.
//
// What the in-memory store fake cannot show: two writes of the marker in
// flight at once. On the first run the server's "yes" writes the marker and
// the profile, the moment it says the first-run screen is done, writes it
// again with onboarded = true. Whatever the disk does with the two writes,
// the marker afterwards must be the last one asked for and readable, or the
// next cold start silently loses the instant stored start.
//
// Plain `test`, not testWidgets: real file I/O does not run under fake time.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/file_last_session_store.dart';
import 'package:sis/features/auth/domain/session_state.dart';

import '../../support/last_session_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Future<void> until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// The marker file has stopped changing for 300 ms (every write landed).
Future<void> settled(File f) async {
  String? last;
  var since = DateTime.now();
  await until(() {
    final now = f.existsSync() ? f.readAsStringSync() : null;
    if (now != last) {
      last = now;
      since = DateTime.now();
      return false;
    }
    return DateTime.now().difference(since) > const Duration(milliseconds: 300);
  }, 'the marker writes to land');
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('sis-marker'));
  tearDown(() => dir.delete(recursive: true));

  FileLastSessionStore store() => FileLastSessionStore(root: () async => dir);

  test('two saves in flight on one store: the marker reads back as the one '
      'asked for last', () async {
    final s = store();
    await Future.wait([
      s.save(marker(onboarded: false)),
      s.save(marker(onboarded: true)),
    ]);

    final got = await store().load();
    expect(got, isNotNull, reason: 'the marker was lost or left corrupt');
    expect(got!.onboarded, isTrue, reason: 'the earlier save won');
  });

  group('saves queued behind one in flight', () {
    // The disk as the store sees it: each look-up of the directory can be
    // held, or fail, so a save is known to be in flight (or broken) while
    // the next ones are called.
    late List<Completer<void>?> holds;
    late Set<int> failing;
    late int asks;
    FileLastSessionStore heldStore() {
      holds = [];
      failing = {};
      asks = 0;
      return FileLastSessionStore(
        root: () async {
          final n = asks++;
          final hold = n < holds.length ? holds[n] : null;
          if (hold != null) await hold.future;
          if (failing.contains(n)) {
            throw const FileSystemException('test: disk unavailable');
          }
          return dir;
        },
      );
    }

    Future<void> done(Iterable<Future<void>> fs) =>
        Future.wait(fs).timeout(const Duration(seconds: 5));

    test('five saves called while the first is held complete in call order, '
        'and the marker is the last one', () async {
      final s = heldStore();
      holds = [Completer<void>()];
      final finished = <int>[];
      final saves = [
        for (var i = 1; i <= 5; i++)
          s.save(marker(sessionId: 'sess-$i')).then((_) => finished.add(i)),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(finished, isEmpty, reason: 'the first save is held');
      holds[0]!.complete();
      await done(saves);

      expect(finished, [1, 2, 3, 4, 5]);
      expect((await store().load())?.sessionId, 'sess-5');
    });

    test('five saves called back to back, nothing held: the marker is the '
        'last one and readable', () async {
      // Each one shorter than the one before: two writes over one file
      // leave the tail of the longer one behind.
      final s = store();
      await done([
        for (var i = 1; i <= 5; i++)
          s.save(marker(sessionId: 'sess-${'x' * (6 - i)}')),
      ]);
      expect((await store().load())?.sessionId, 'sess-x');
    });

    test('a failed save does not block the next: it completes and its '
        'marker is stored', () async {
      final s = heldStore();
      holds = [Completer<void>()];
      failing = {0};
      final bad = s.save(marker(sessionId: 'sess-bad'));
      final good = s.save(marker(sessionId: 'sess-good'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      holds[0]!.complete();
      await done([bad, good]);

      expect((await store().load())?.sessionId, 'sess-good');
    });

    test(
      'a failed save with nothing queued, then a later save: stored',
      () async {
        final s = heldStore();
        failing = {0};
        await done([s.save(marker(sessionId: 'sess-bad'))]);
        await done([s.save(marker(sessionId: 'sess-good'))]);
        expect((await store().load())?.sessionId, 'sess-good');
      },
    );

    test('clear() called after a save that has not started yet wins', () async {
      final s = heldStore();
      holds = [Completer<void>()];
      final first = s.save(marker(sessionId: 'sess-1'));
      final queued = s.save(marker(sessionId: 'sess-2')); // waits for first
      final cleared = s.clear();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      holds[0]!.complete();
      await done([first, queued, cleared]);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        dir.listSync().map((e) => e.path.split('/').last),
        isEmpty,
        reason: 'a queued save resurrected the marker after clear()',
      );
      expect(await store().load(), isNull);
    });

    test('a save called after clear() is kept', () async {
      final s = heldStore();
      holds = [Completer<void>()];
      final first = s.save(marker(sessionId: 'sess-1'));
      final cleared = s.clear();
      final after = s.save(marker(sessionId: 'sess-3'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      holds[0]!.complete();
      await done([first, cleared, after]);

      expect((await store().load())?.sessionId, 'sess-3');
    });
  });

  test('the profile says onboarded the moment the server confirms: the next '
      'cold start shows the stored state before the server answers', () async {
    ProviderContainer rig(ColdAuth auth) => ProviderContainer(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(auth),
        lastSessionStoreProvider.overrideWithValue(store()),
      ],
    );

    // First run: no marker, so the gated path; the server says yes at once,
    // and the profile (already cached) says the first-run screen is done.
    final first = rig(ColdAuth(autoAllow: true));
    first.listen(sessionControllerProvider, (_, next) {
      if (next.value case final Allowed a when a.confirmed) {
        first.read(sessionControllerProvider.notifier).markOnboarded();
      }
    }, fireImmediately: true);
    await until(
      () => switch (first.read(sessionControllerProvider).value) {
        final Allowed a => a.confirmed,
        _ => false,
      },
      'the gated confirm',
    );
    final file = File('${dir.path}/last_session.json');
    await settled(file);
    final onDisk = file.existsSync() ? file.readAsStringSync() : 'no file';
    first.dispose();

    // Next cold start, the server check held in flight.
    final auth = ColdAuth();
    final next = rig(auth);
    addTearDown(next.dispose);
    final states = <SessionState>[];
    next.listen(sessionControllerProvider, (_, s) {
      if (s.value case final v?) states.add(v);
    }, fireImmediately: true);
    await until(
      () => states.isNotEmpty || auth.checks.isNotEmpty,
      'the start to show something or ask the server',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      states,
      isNotEmpty,
      reason: 'the gated path ran, waiting on the server; marker: $onDisk',
    );
    expect(
      states.first,
      isA<Allowed>()
          .having((a) => a.confirmed, 'confirmed', isFalse)
          .having((a) => a.onboarded, 'onboarded', isTrue),
      reason: 'marker: $onDisk',
    );
  });
}
