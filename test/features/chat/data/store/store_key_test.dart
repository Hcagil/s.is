import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dart:convert';

import 'package:sis/features/chat/data/store/store_key.dart';

List<int> keyBytes(String k) {
  final bytes = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(k)
      ? List<int>.generate(
          32,
          (i) => int.parse(k.substring(i * 2, i * 2 + 2), radix: 16),
        )
      : (() {
          try {
            return base64.decode(k);
          } catch (_) {
            return base64Url.decode(k);
          }
        })();
  assert(bytes.length == 32);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StoreKey', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('fresh loadOrCreate returns 32‑byte key and stores it', () async {
      final storeKey = const StoreKey();
      final key = await storeKey.loadOrCreate();
      expect(keyBytes(key).length, 32);
      final stored = await const FlutterSecureStorage().read(
        key: 'sis.store.key',
      );
      expect(stored, key);
    });

    test('second loadOrCreate returns the same key', () async {
      final key1 = await const StoreKey().loadOrCreate();
      final key2 = await const StoreKey().loadOrCreate();
      expect(key1, key2);
    });

    test('pre‑stored value is returned unchanged', () async {
      const hex =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      FlutterSecureStorage.setMockInitialValues({'sis.store.key': hex});
      final key = await const StoreKey().loadOrCreate();
      expect(key, hex);
      final stored = await const FlutterSecureStorage().read(
        key: 'sis.store.key',
      );
      expect(stored, hex);
    });

    test('two fresh stores produce different keys', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final key1 = await const StoreKey().loadOrCreate();
      FlutterSecureStorage.setMockInitialValues({});
      final key2 = await const StoreKey().loadOrCreate();
      expect(key1, isNot(equals(key2)));
    });

    test('delete removes key and next loadOrCreate gives new key', () async {
      final storeKey = const StoreKey();
      final key1 = await storeKey.loadOrCreate();
      await storeKey.delete();
      final afterDelete = await const FlutterSecureStorage().read(
        key: 'sis.store.key',
      );
      expect(afterDelete, isNull);
      final key2 = await storeKey.loadOrCreate();
      expect(key1, isNot(equals(key2)));
    });
  });
}
