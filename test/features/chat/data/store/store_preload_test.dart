import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String keyA;

  setUp(() async {
    DriftMessageStore.resetPrefetchForTest();
    h = await StoreHarness.create();
    keyA = await h.newKey();
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

  Future<void> seed({String id = 'm1', String? key, StoreHarness? at}) async {
    final s = store(key: key, at: at);
    await s.upsertAll([msg(id)]);
    await s.close();
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

  Future<void> prefetch() async {
    await DriftMessageStore.prefetchKey(() async => keyA);
  }

  test('preload value comes back', () async {
    await seed();
    await prefetch();
    var counter = 0;
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        counter++;
        return 'P1';
      },
    );
    expect(counter, 1);
    final value = await DriftMessageStore.takePreloaded('owner-1');
    expect(value, 'P1');
  });

  test('single use', () async {
    await seed();
    await prefetch();
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async => 'P1',
    );
    expect(await DriftMessageStore.takePreloaded('owner-1'), 'P1');
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });

  test('owner mismatch', () async {
    await seed();
    await prefetch();
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async => 'P1',
    );
    expect(await DriftMessageStore.takePreloaded('owner-2'), isNull);
  });

  test('takePreloaded waits for early open', () async {
    await seed();
    await prefetch();
    final gate = Completer<void>();
    final warm = DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        await gate.future;
        return 'P1';
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final future = DriftMessageStore.takePreloaded('owner-1');
    var completed = false;
    future.then((_) => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(completed, isFalse);
    gate.complete();
    await warm;
    expect(await future, 'P1');
  });

  test('no owner_id row', () async {
    await seed();
    await store().run<void>(null, (db) async {
      await db.customStatement('DELETE FROM meta WHERE key = ?', ['owner_id']);
    }, write: true);
    await store().close();
    DriftMessageStore.resetPrefetchForTest();
    await prefetch();
    var counter = 0;
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        counter++;
        return 'P1';
      },
    );
    expect(counter, 0);
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });

  test('file does not exist', () async {
    var counter = 0;
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        counter++;
        return 'P1';
      },
    );
    expect(counter, 0);
    expect(h.file.existsSync(), isFalse);
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });

  test('preload throws', () async {
    await seed();
    await prefetch();
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await DriftMessageStore.warmOpen(
        () async => h.file,
        preload: (db) async {
          throw StateError('boom');
        },
      );
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
    await h.file.delete();
    expect(await read(store()), [
      'm1',
    ], reason: 'the early db survives a preload throw');
  });

  test('erase after the early open', () async {
    await seed();
    await prefetch();
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async => 'P1',
    );
    await store().clear();
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });

  test('erase while the preload runs: nothing is handed out', () async {
    await seed();
    await prefetch();
    final gate = Completer<void>();
    final warm = DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        await gate.future;
        return 'P1';
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final erase = store().clear();
    gate.complete();
    await Future.wait([warm, erase]);
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });

  test('no preload passed', () async {
    await seed();
    await prefetch();
    await DriftMessageStore.warmOpen(() async => h.file);
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });

  test('without any warmOpen', () async {
    await seed();
    await prefetch();
    expect(await DriftMessageStore.takePreloaded('owner-1'), isNull);
  });
}
