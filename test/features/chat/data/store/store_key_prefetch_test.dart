// Store key prefetch at cold start, written from the contract of
// DriftMessageStore.prefetchKey (never from its implementation): the read
// runs once, its value serves the FIRST store open only, an erase (clear())
// before or during the read drops it, a value arriving after the first open
// is ignored, and a failed or empty read falls back to the lazy `key:`
// closure without surfacing anything. Stores are REAL SQLite3 Multiple
// Ciphers files (StoreHarness), so "the prefetched key was used" is proven by
// the file it encrypted, not by a call count alone.
//
// StartupMarks logs a label once per process, so the mark test is FIRST in
// this file (one isolate per file, tests run in order).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, DebugPrintCallback;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/store_key.dart';

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String keyA;
  late String keyB;

  setUp(() async {
    DriftMessageStore.resetPrefetchForTest();
    h = await StoreHarness.create();
    keyA = await h.newKey();
    keyB = await h.newKey();
    expect(keyA, isNot(keyB));
  });

  /// A store on the harness file whose lazy `key:` closure counts its calls.
  ({DriftMessageStore store, int Function() calls}) counted(String key) {
    var n = 0;
    final s = DriftMessageStore(
      ownerId: 'owner-1',
      file: () async => h.file,
      key: () async {
        n++;
        return key;
      },
      deleteKey: () async => h.deleteKeyCalls++,
    );
    addTearDown(s.close);
    return (store: s, calls: () => n);
  }

  /// Opens the store (any read opens it).
  Future<void> open(DriftMessageStore s) => s
      .newest('c1')
      .timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('store open hung (waits for the prefetch?)'),
      );

  test('AC-4: mark store-key-prefetched once on a completed read, '
      'none on a throw', () async {
    final lines = <String>[];
    final DebugPrintCallback saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) lines.add(m);
    };
    addTearDown(() => debugPrint = saved);
    Iterable<String> marks() =>
        lines.where((l) => l.startsWith('sis.startup store-key-prefetched '));

    await DriftMessageStore.prefetchKey(() async => throw StateError('x'));
    await DriftMessageStore.prefetchKey(() => throw StateError('sync'));
    expect(marks(), isEmpty, reason: 'a throwing read records no mark');

    DriftMessageStore.resetPrefetchForTest();
    await DriftMessageStore.prefetchKey(() async => null);
    expect(marks(), hasLength(1), reason: 'a null read still completed');

    DriftMessageStore.resetPrefetchForTest();
    await DriftMessageStore.prefetchKey(() async => keyA);
    expect(marks(), hasLength(1), reason: 'logged once');
  });

  group('AC-2 use', () {
    test('the first open uses the prefetched key and skips the closure; '
        'a second open calls the closure', () async {
      await DriftMessageStore.prefetchKey(() async => keyA);

      // Closure would give B: if the file ends up keyed with A, the
      // prefetched value is what opened it.
      final first = counted(keyB);
      await first.store.upsertAll([msg('m1')]);
      expect(first.calls(), 0, reason: 'first open must not call key:');
      await first.store.close();

      final second = counted(keyA);
      expect(ids(await second.store.newest('c1')), [
        'm1',
      ], reason: 'the file was encrypted with the prefetched key A');
      expect(second.calls(), 1, reason: 'the prefetched key is used once');
    });
  });

  group('AC-2 erase', () {
    test('clear() after the prefetch drops the value', () async {
      await DriftMessageStore.prefetchKey(() async => keyA);
      await counted(keyA).store.clear();

      final next = counted(keyA);
      await open(next.store);
      expect(next.calls(), 1);
    });

    test('clear() while the read is pending discards the value', () async {
      final read = Completer<String?>();
      final done = DriftMessageStore.prefetchKey(() => read.future);
      await counted(keyA).store.clear();
      read.complete(keyA);
      await done;

      final next = counted(keyA);
      await open(next.store);
      expect(next.calls(), 1);
    });
  });

  test('AC-2 late arrival: a value arriving after the first open is '
      'ignored', () async {
    final read = Completer<String?>();
    final done = DriftMessageStore.prefetchKey(() => read.future);

    final first = counted(keyA);
    await open(first.store);
    expect(first.calls(), 1, reason: 'no value yet: the lazy read runs');

    read.complete(keyB);
    await done;

    final second = counted(keyA);
    await second.store.upsertAll([msg('m1')]);
    expect(second.calls(), 1, reason: 'the late value is not served');
  });

  group('AC-3 fallback', () {
    for (final (name, read) in <(String, Future<String?> Function())>[
      ('async throw', () async => throw StateError('keychain locked')),
      ('sync throw', () => throw StateError('keychain locked')),
      ('null', () async => null),
    ]) {
      test('$name: prefetchKey completes, the lazy closure runs', () async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          await expectLater(DriftMessageStore.prefetchKey(read), completes);
        }, (e, _) => errors.add(e));
        expect(errors, isEmpty, reason: 'nothing surfaced');

        final s = counted(keyA);
        await s.store.upsertAll([msg('m1')]);
        expect(s.calls(), 1);
        expect(ids(await s.store.newest('c1')), ['m1']);
      });
    }
  });

  group('AC-1 read-only', () {
    test('StoreKey.peek on an empty keychain returns null and writes '
        'nothing', () async {
      FlutterSecureStorage.setMockInitialValues({});
      expect(await const StoreKey().peek(), isNull);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    });

    test('main.dart prefetches with peek(), after guardLostPickleKey and '
        'before Supabase.initialize, without awaiting', () {
      final src = File('lib/main.dart').readAsStringSync();
      final at = src.indexOf('DriftMessageStore.prefetchKey(');
      expect(at, greaterThan(0));
      final call = src.substring(at, src.indexOf(');', at));
      expect(call, contains('.peek()'));
      expect(call, isNot(contains('loadOrCreate')));
      expect(
        RegExp(r'unawaited\(\s*$').hasMatch(src.substring(0, at)),
        isTrue,
        reason: 'the read runs in parallel, not awaited',
      );
      expect(src.indexOf('guardLostPickleKey('), inInclusiveRange(0, at));
      expect(src.indexOf('Supabase.initialize('), greaterThan(at));
    });
  });
}
