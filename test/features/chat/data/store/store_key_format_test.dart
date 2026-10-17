// A stored key that is not exactly 64 lowercase hex characters is treated as
// missing: StoreKey makes and saves a new valid one, and the store opens
// with it.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/store_key.dart';

import 'store_harness.dart';

final _valid = RegExp(r'^[0-9a-f]{64}$');

void main() {
  final bad = {
    'uppercase hex': 'ABCDEF0123456789' * 4,
    '63 characters': '0123456789abcdef' * 3 + '0123456789abcde',
    'not hex': 'g' * 64,
  };

  for (final MapEntry(key: name, value: stored) in bad.entries) {
    test('$name: replaced by a new valid key, and the store opens', () async {
      final h = await StoreHarness.create();
      FlutterSecureStorage.setMockInitialValues({'sis.store.key': stored});
      final key = await const StoreKey().loadOrCreate();
      expect(key, matches(_valid));
      expect(key, isNot(stored));
      expect(
        await const FlutterSecureStorage().read(key: 'sis.store.key'),
        key,
      );
      expect(await const StoreKey().loadOrCreate(), key, reason: 'kept');

      final s = h.open(owner: 'owner-1', key: key);
      await s.upsertAll([msg('a')]);
      expect(ids(await s.newest('c1')), ['a']);
      expect(ids(await h.open(owner: 'owner-1', key: key).newest('c1')), ['a']);
    });
  }

  test('a valid lowercase key is kept as it is', () async {
    final good = '0123456789abcdef' * 4;
    FlutterSecureStorage.setMockInitialValues({'sis.store.key': good});
    expect(await const StoreKey().loadOrCreate(), good);
  });
}
