// DriftOlmPickleStore.update against a real encrypted store file, written from the OlmPickleStore contract.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';

import '../../chat/data/store/store_harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('update', () {
    late StoreHarness h;
    late DriftMessageStore store;
    late DriftOlmPickleStore pickleStore;

    setUp(() async {
      h = await StoreHarness.create();
      store = h.open(owner: 'bob', key: await h.newKey());
      addTearDown(store.close);
      pickleStore = DriftOlmPickleStore(store);
    });

    Future<void> exec(String sql) =>
        store.run<void>(null, (db) => db.customStatement(sql));

    test('no pickle: change receives null; change returns P1', () async {
      final seen = <String?>['unset'];
      final result = await pickleStore.update((current) async {
        seen[0] = current;
        return 'P1';
      });
      expect(result, true);
      expect(seen.single, isNull);
      expect(await pickleStore.load(), 'P1');
    });

    test('existing pickle P0: change receives P0; returns P1', () async {
      await pickleStore.save('P0');
      String? seen;
      final result = await pickleStore.update((current) async {
        seen = current;
        return 'P1';
      });
      expect(result, true);
      expect(seen, 'P0');
      expect(await pickleStore.load(), 'P1');
    });

    test('change returns null: update returns true, load unchanged', () async {
      // With existing pickle
      await pickleStore.save('P0');
      var result = await pickleStore.update((current) async => null);
      expect(result, true);
      expect(await pickleStore.load(), 'P0');

      // With no pickle
      final h2 = await StoreHarness.create();
      final store2 = h2.open(owner: 'bob', key: await h2.newKey());
      addTearDown(store2.close);
      final pickleStore2 = DriftOlmPickleStore(store2);
      result = await pickleStore2.update((current) async => null);
      expect(result, true);
      expect(await pickleStore2.load(), null);
    });

    test('change throws: update returns false, load unchanged', () async {
      await pickleStore.save('P0');
      final result = await pickleStore.update(
        (current) async => throw StateError('x'),
      );
      expect(result, false);
      expect(await pickleStore.load(), 'P0');
    });

    test(
      'forced write failure: update returns false, load unchanged',
      () async {
        await pickleStore.save('P0');
        await exec(
          "CREATE TRIGGER fail_tx BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT, 'forced'); END",
        );
        await exec(
          "CREATE TRIGGER fail_tx2 BEFORE INSERT ON meta BEGIN SELECT RAISE(ABORT, 'forced'); END",
        );
        final result = await pickleStore.update((current) async => 'P1');
        expect(result, false);
        await exec("DROP TRIGGER IF EXISTS fail_tx");
        await exec("DROP TRIGGER IF EXISTS fail_tx2");
        expect(await pickleStore.load(), 'P0');
      },
    );

    test('store closed: update returns false, change not called', () async {
      await pickleStore.save('P0');
      await store.close();
      final result = await pickleStore.update((current) async => 'P1');
      expect(result, false);
    });

    test('no lost update: concurrent updates succeed', () async {
      await pickleStore.save('x');
      final future1 = pickleStore.update((current) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return '${current}a';
      });
      final future2 = pickleStore.update((current) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return '${current}b';
      });
      final results = await Future.wait([future1, future2]);
      expect(results, [true, true]);
      final loaded = await pickleStore.load();
      expect(loaded, anyOf('xab', 'xba'));
    });

    test('update then load agree with save', () async {
      await pickleStore.save('S');
      final result = await pickleStore.update((current) async => null);
      expect(result, true);
      expect(await pickleStore.load(), 'S');
    });
  });
}
