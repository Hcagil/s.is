// The early store open at app start, written from the contract of
// DriftMessageStore.prefetchKey + DriftMessageStore.warmOpen (slice 2,
// t_f79a5084b0), never from the implementation:
// - warmOpen opens only a file that already exists, with the prefetched key;
//   it never makes a file;
// - the first store open reuses that database once; later opens are fresh;
// - an erase (clear() on any store) before the early db is taken, or while
//   it opens: the next open is fresh, no old rows;
// - a path or key mismatch: fresh open;
// - no prefetched key / key already taken / no file / a throw: the lazy open;
// - the owner check still runs on the reused database.
// Stores are REAL encrypted files (StoreHarness). "Reused" is proven by the
// file: after warmOpen the file is unlinked, so only the already-open early
// database can still show its rows; a fresh open finds no file.
// StartupMarks logs a label once per process: the mark test is FIRST.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, DebugPrintCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'store_harness.dart';

/// The store file; [onFirstPath] runs (once) on the first read of [path].
class _HookFile implements File {
  _HookFile(this._real, this._onFirstPath);
  final File _real;
  void Function()? _onFirstPath;

  @override
  String get path {
    final hook = _onFirstPath;
    _onFirstPath = null;
    hook?.call();
    return _real.path;
  }

  @override
  Future<bool> exists() => _real.exists();

  @override
  bool existsSync() => _real.existsSync();

  @override
  File get absolute => _real.absolute;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('_HookFile.${i.memberName}');
}

void main() {
  late StoreHarness h;
  late String keyA;

  setUp(() async {
    DriftMessageStore.resetPrefetchForTest();
    h = await StoreHarness.create();
    keyA = await h.newKey();
    // Drops any early db the test left behind (reset does not close it).
    addTearDown(DriftMessageStore.resetPrefetchForTest);
  });

  DriftMessageStore store({
    String owner = 'owner-1',
    String? key,
    StoreHarness? at,
    void Function()? onKey,
  }) {
    final s = DriftMessageStore(
      ownerId: owner,
      file: () async => (at ?? h).file,
      key: () async {
        onKey?.call();
        return key ?? keyA;
      },
      deleteKey: () async => h.deleteKeyCalls++,
    );
    addTearDown(s.close);
    return s;
  }

  /// A file from an earlier run: owner-1, keyed [key], holding [id].
  Future<void> seed({String id = 'm1', String? key, StoreHarness? at}) async {
    final s = store(key: key, at: at);
    await s.upsertAll([msg(id)]);
    await s.close();
    // That open counted as the process's first: start the next run clean.
    DriftMessageStore.resetPrefetchForTest();
  }

  Future<List<String>> read(DriftMessageStore s) async => ids(
    await s
        .newest('c1')
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('store open hung'),
        ),
  );

  Future<void> early() async {
    await DriftMessageStore.prefetchKey(() async => keyA);
    await DriftMessageStore.warmOpen(() async => h.file);
  }

  test('marks: one early-open-start, early-open-end, store-open', () async {
    final lines = <String>[];
    final DebugPrintCallback saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) lines.add(m);
    };
    addTearDown(() => debugPrint = saved);
    // Captured from the seed on: a mark logs once per process.
    await seed();
    await early();
    expect(await read(store()), ['m1']);
    for (final label in ['early-open-start', 'early-open-end', 'store-open']) {
      expect(
        lines.where((l) => l.startsWith('sis.startup $label ')),
        hasLength(1),
        reason: label,
      );
    }
  });

  test('the first open reuses the early database, once', () async {
    await seed();
    await early();
    await h.file.delete();
    final first = store();
    expect(await read(first), ['m1'], reason: 'served by the early database');
    // The first store stays open: a second taker must not share its db.
    expect(await read(store()), isEmpty, reason: 'single use: a fresh open');
  });

  test('warmOpen never makes a file', () async {
    await early();
    expect(h.file.existsSync(), isFalse);
    expect(await read(store()), isEmpty, reason: 'the lazy open still works');
  });

  test('clear() after the early open: the next open is fresh', () async {
    await seed();
    await early();
    await store().clear();
    expect(await read(store()), isEmpty);
  });

  test('clear() while the early open runs: the next open is fresh', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => keyA);
    final gate = Completer<void>();
    final warm = DriftMessageStore.warmOpen(() async {
      await gate.future;
      return h.file;
    });
    final erase = store().clear();
    gate.complete();
    await Future.wait([warm, erase]);
    expect(await read(store()), isEmpty);
  });

  test('clear() racing the early open: no old rows', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => keyA);
    final warm = DriftMessageStore.warmOpen(() async => h.file);
    final erase = store().clear();
    await Future.wait([warm, erase]);
    expect(await read(store()), isEmpty);
  });

  test('a different path: a fresh open of that path', () async {
    final h2 = await StoreHarness.create();
    await seed();
    await seed(id: 'm2', at: h2);
    await early();
    expect(await read(store(at: h2)), ['m2']);
  });

  test('no prefetched key: warmOpen opens nothing', () async {
    await seed();
    await DriftMessageStore.warmOpen(() async => h.file);
    await h.file.delete();
    expect(await read(store()), isEmpty);
  });

  test('prefetched key already taken: warmOpen opens nothing', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => keyA);
    final first = store();
    expect(await read(first), ['m1']);
    await first.close();
    await DriftMessageStore.warmOpen(() async => h.file);
    await h.file.delete();
    expect(await read(store()), isEmpty);
  });

  for (final (name, file) in <(String, Future<Never> Function())>[
    ('async throw', () async => throw StateError('no dir')),
    ('sync throw', () => throw StateError('no dir')),
  ]) {
    test(
      'file lookup $name: warmOpen completes, the lazy open works',
      () async {
        await seed();
        await DriftMessageStore.prefetchKey(() async => keyA);
        final errors = <Object>[];
        await runZonedGuarded(() async {
          await expectLater(DriftMessageStore.warmOpen(file), completes);
        }, (e, _) => errors.add(e));
        expect(errors, isEmpty);
        expect(await read(store()), ['m1']);
      },
    );
  }

  // Security gate (red until the fix): an erase that starts after warmOpen
  // checked the file, while the early database is still opening, must leave
  // no store file on disk (the early open must not re-create it). The erase
  // starts the first time warmOpen reads the file's path, which is after
  // the existence check.
  test('clear() while the early open is in flight: no store file is left '
      'on disk, and the next open is fresh', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => keyA);
    final eraser = store();
    Future<void>? erase;
    final warm = DriftMessageStore.warmOpen(
      () async => _HookFile(h.file, () => erase = eraser.clear()),
    );
    await warm;
    expect(erase, isNotNull, reason: 'fixture: the erase ran mid-open');
    await erase;
    // Let any late query of the early database run.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(h.file.existsSync(), isFalse, reason: 'the erase left a file');
    expect(await read(store()), isEmpty, reason: 'the next open is fresh');
  });

  test('the owner check runs on the reused database', () async {
    await seed();
    await early();
    expect(await read(store(owner: 'owner-2')), isEmpty);
  });
}
