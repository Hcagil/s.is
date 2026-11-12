import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/data/admin_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  const keyName = 'sis.admin.panels';

  AdminKeys _makeKeys({
    List<int>? secret,
    List<int>? public,
    List<int>? pinned,
    bool published = false,
    int pinnedEpoch = 0,
    int upEpoch = 0,
    int upSeq = 0,
    int downEpoch = 0,
    int downSeq = 0,
  }) {
    return AdminKeys(
      secret: secret ?? List.filled(32, 1),
      public: public ?? List.filled(32, 2),
      pinned: pinned,
      published: published,
      pinnedEpoch: pinnedEpoch,
      upEpoch: upEpoch,
      upSeq: upSeq,
      downEpoch: downEpoch,
      downSeq: downSeq,
    );
  }

  test('1. nothing stored -> load() is null', () async {
    final store = AdminKeyStore();
    expect(await store.load(), isNull);
  });

  test('2. save then load round-trips every field', () async {
    final store = AdminKeyStore();
    final keys = _makeKeys(
      secret: List.filled(32, 1),
      public: List.filled(32, 2),
      pinned: List.filled(32, 3),
      published: true,
      pinnedEpoch: 4,
      upEpoch: 5,
      upSeq: 6,
      downEpoch: 7,
      downSeq: 8,
    );
    await store.save(keys);
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.secret, equals(keys.secret));
    expect(loaded.public, equals(keys.public));
    expect(loaded.pinned, equals(keys.pinned));
    expect(loaded.published, equals(keys.published));
    expect(loaded.pinnedEpoch, equals(keys.pinnedEpoch));
    expect(loaded.upEpoch, equals(keys.upEpoch));
    expect(loaded.upSeq, equals(keys.upSeq));
    expect(loaded.downEpoch, equals(keys.downEpoch));
    expect(loaded.downSeq, equals(keys.downSeq));
  });

  test('3. persistence across instances', () async {
    final store1 = AdminKeyStore();
    final keys = _makeKeys(upSeq: 6, downSeq: 8);
    await store1.save(keys);

    final store2 = AdminKeyStore();
    final loaded2 = await store2.load();
    expect(loaded2, isNotNull);
    expect(loaded2!.upSeq, equals(6));
    expect(loaded2.downSeq, equals(8));

    final updatedKeys = loaded2.copyWith(upSeq: 7);
    await store2.save(updatedKeys);

    final store3 = AdminKeyStore();
    final loaded3 = await store3.load();
    expect(loaded3, isNotNull);
    expect(loaded3!.upSeq, equals(7));
    expect(loaded3.downSeq, equals(8));
  });

  test('4. delete() then load() is null; delete when nothing stored does not throw', () async {
    final store = AdminKeyStore();
    await store.delete(); // should not throw
    expect(await store.load(), isNull);

    final keys = _makeKeys();
    await store.save(keys);
    await store.delete();
    expect(await store.load(), isNull);
  });

  test('5. withoutPin', () async {
    final store = AdminKeyStore();
    final keys = _makeKeys(pinned: List.filled(32, 3));
    final withoutPin = keys.withoutPin();
    expect(withoutPin.pinned, isNull);
    expect(withoutPin.pinnedEpoch, equals(0));
    expect(withoutPin.secret, equals(keys.secret));
    expect(withoutPin.public, equals(keys.public));

    await store.save(withoutPin);
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.pinned, isNull);
    expect(loaded.pinnedEpoch, equals(0));
  });

  group('6. unusable data', () {
    Future<void> _writeRaw(String value) async {
      await const FlutterSecureStorage().write(key: keyName, value: value);
    }

    test('not json', () async {
      await _writeRaw('not json');
      expect(await AdminKeyStore().load(), isNull);
    });

    test('v=2', () async {
      final data = {
        'v': 2,
        'sk': base64Encode(List.filled(32, 7)),
        'pk': base64Encode(List.filled(32, 8)),
      };
      await _writeRaw(jsonEncode(data));
      expect(await AdminKeyStore().load(), isNull);
    });

    test('sk 31 bytes', () async {
      final data = {
        'v': 1,
        'sk': base64Encode(List.filled(31, 7)),
        'pk': base64Encode(List.filled(32, 8)),
      };
      await _writeRaw(jsonEncode(data));
      expect(await AdminKeyStore().load(), isNull);
    });

    test('pk 33 bytes', () async {
      final data = {
        'v': 1,
        'sk': base64Encode(List.filled(32, 7)),
        'pk': base64Encode(List.filled(33, 8)),
      };
      await _writeRaw(jsonEncode(data));
      expect(await AdminKeyStore().load(), isNull);
    });

    test('pin 5 bytes', () async {
      final data = {
        'v': 1,
        'sk': base64Encode(List.filled(32, 7)),
        'pk': base64Encode(List.filled(32, 8)),
        'pin': base64Encode(List.filled(5, 9)),
      };
      await _writeRaw(jsonEncode(data));
      expect(await AdminKeyStore().load(), isNull);
    });

    test('missing pk', () async {
      final data = {
        'v': 1,
        'sk': base64Encode(List.filled(32, 7)),
      };
      await _writeRaw(jsonEncode(data));
      expect(await AdminKeyStore().load(), isNull);
    });

    test('empty array', () async {
      await _writeRaw('[]');
      expect(await AdminKeyStore().load(), isNull);
    });
  });

  test('7. read error is not swallowed', () async {
    // First store valid data
    final normalStore = AdminKeyStore();
    final keys = _makeKeys();
    await normalStore.save(keys);

    // Verify data exists
    final storedValue = await const FlutterSecureStorage().read(key: keyName);
    expect(storedValue, isNotNull);

    // Now use broken storage
    final brokenStore = AdminKeyStore(const _BrokenStorage());
    await expectLater(
      brokenStore.load(),
      throwsA(isA<PlatformException>()),
    );

    // Ensure data was not deleted
    final afterError = await const FlutterSecureStorage().read(key: keyName);
    expect(afterError, equals(storedValue));
  });
}

class _BrokenStorage extends FlutterSecureStorage {
  const _BrokenStorage();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(code: 'keystore');
  }
}
