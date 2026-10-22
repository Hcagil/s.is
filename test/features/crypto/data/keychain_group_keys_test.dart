// StoreKey and PickleKey in the iOS crypto keychain group, with the old
// default group as the fallback, over the real flutter_secure_storage plugin
// call path (test/support/group_keychain.dart stands in for the keychain).
// Written from the contract: setAsideStore runs once, before the write, only
// when neither group holds a valid 64-hex key; PickleKey refuses to make a new
// key exactly when pickles exist and the key is gone from both groups.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/crypto/data/pickle_key.dart';

import '../../../support/group_keychain.dart';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late GroupKeychain kc;
  late int setAsides;
  Future<void> setAside() async {
    setAsides++;
    kc.log.add('setAside');
  }

  setUp(() {
    kc = GroupKeychain()..install();
    setAsides = 0;
  });

  group('StoreKey.loadOrCreate(setAsideStore:)', () {
    test('inGroup(null): a new key never sets the store aside', () async {
      final key = await StoreKey.inGroup(null)
          .loadOrCreate(setAsideStore: setAside);
      expect(key, matches(_hex64));
      expect(setAsides, 0);
      expect(kc.get(null, storeKeyName), key);
    });

    test('inGroup(g), no key in either group: set aside once, before the '
        'write, and the new key goes to the crypto group', () async {
      final key = await StoreKey.inGroup(cryptoGroup)
          .loadOrCreate(setAsideStore: setAside);
      expect(key, matches(_hex64));
      expect(setAsides, 1);
      final aside = kc.log.indexOf('setAside');
      final write = kc.log.indexWhere((l) => l.startsWith('write '));
      expect(write, greaterThan(aside), reason: kc.log.join('\n'));
      expect(kc.get(cryptoGroup, storeKeyName), key);
      expect(kc.get(null, storeKeyName), isNull);
    });

    test('inGroup(g), valid key in the crypto group: returned, nothing set '
        'aside, nothing written', () async {
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      final key = await StoreKey.inGroup(cryptoGroup)
          .loadOrCreate(setAsideStore: setAside);
      expect(key, validKeyA);
      expect(setAsides, 0);
      expect(kc.writes(), isEmpty);
    });

    test('inGroup(g), key only in the old default group: returned, nothing '
        'set aside', () async {
      kc.put(null, storeKeyName, validKeyB);
      final key = await StoreKey.inGroup(cryptoGroup)
          .loadOrCreate(setAsideStore: setAside);
      expect(key, validKeyB);
      expect(setAsides, 0);
    });

    test('inGroup(g), invalid key in the crypto group and a valid one in the '
        'default group: the valid one, nothing set aside', () async {
      kc.put(cryptoGroup, storeKeyName, 'A1' * 32); // upper case: not valid
      kc.put(null, storeKeyName, validKeyB);
      final key = await StoreKey.inGroup(cryptoGroup)
          .loadOrCreate(setAsideStore: setAside);
      expect(key, validKeyB);
      expect(setAsides, 0);
    });

    test('inGroup(g), only invalid keys in both groups: set aside once, then '
        'a new valid key', () async {
      kc.put(cryptoGroup, storeKeyName, 'abc');
      kc.put(null, storeKeyName, 'f' * 63);
      final key = await StoreKey.inGroup(cryptoGroup)
          .loadOrCreate(setAsideStore: setAside);
      expect(setAsides, 1);
      expect(key, matches(_hex64));
      expect(kc.get(cryptoGroup, storeKeyName), key);
    });

    test('inGroup(g) without setAsideStore still makes a key', () async {
      final key = await StoreKey.inGroup(cryptoGroup).loadOrCreate();
      expect(key, matches(_hex64));
    });

    test('peek reads either group and never writes', () async {
      expect(await StoreKey.inGroup(cryptoGroup).peek(), isNull);
      kc.put(null, storeKeyName, validKeyB);
      expect(await StoreKey.inGroup(cryptoGroup).peek(), validKeyB);
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      expect(await StoreKey.inGroup(cryptoGroup).peek(), validKeyA);
      expect(kc.writes(), isEmpty);
    });

    test('delete clears the key in both groups', () async {
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      kc.put(null, storeKeyName, validKeyB);
      await StoreKey.inGroup(cryptoGroup).delete();
      expect(kc.get(cryptoGroup, storeKeyName), isNull);
      expect(kc.get(null, storeKeyName), isNull);
    });
  });

  group('PickleKey.inGroup(g, hasPickles:)', () {
    test('missing in both groups, group set, pickles stored: StateError and '
        'no key written', () async {
      final k = PickleKey.inGroup(cryptoGroup, hasPickles: () async => true);
      await expectLater(k.loadOrCreate(), throwsStateError);
      expect(kc.writes(), isEmpty);
    });

    test('missing in both groups, group set, no pickles: a new key in the '
        'crypto group', () async {
      final k = PickleKey.inGroup(cryptoGroup, hasPickles: () async => false);
      final key = await k.loadOrCreate();
      expect(key, hasLength(32));
      expect(kc.get(cryptoGroup, pickleKeyName), _hex(key));
    });

    test('missing, no group (Android, unsigned build), pickles stored: a new '
        'key, no error', () async {
      final k = PickleKey.inGroup(null, hasPickles: () async => true);
      final key = await k.loadOrCreate();
      expect(key, hasLength(32));
      expect(kc.get(null, pickleKeyName), _hex(key));
    });

    test('missing in both groups, group set, hasPickles not given: a new '
        'key, no error', () async {
      final key = await PickleKey.inGroup(cryptoGroup).loadOrCreate();
      expect(key, hasLength(32));
    });

    test('key only in the default group, pickles stored: that key', () async {
      kc.put(null, pickleKeyName, validKeyB);
      final k = PickleKey.inGroup(cryptoGroup, hasPickles: () async => true);
      expect(_hex(await k.loadOrCreate()), validKeyB);
    });

    test('key in the crypto group, pickles stored: that key', () async {
      kc.put(cryptoGroup, pickleKeyName, validKeyA);
      final k = PickleKey.inGroup(cryptoGroup, hasPickles: () async => true);
      expect(_hex(await k.loadOrCreate()), validKeyA);
      expect(kc.writes(), isEmpty);
    });

    test(
      'only invalid keys in both groups, pickles stored: StateError',
      () async {
        kc.put(cryptoGroup, pickleKeyName, 'zz' * 32);
        kc.put(null, pickleKeyName, 'abc');
        final k = PickleKey.inGroup(cryptoGroup, hasPickles: () async => true);
        await expectLater(k.loadOrCreate(), throwsStateError);
        expect(kc.writes(), isEmpty);
      },
    );

    test(
      'exists: true for a valid key in either group, never writes',
      () async {
        final k = PickleKey.inGroup(cryptoGroup);
        expect(await k.exists(), isFalse);
        kc.put(null, pickleKeyName, 'abc');
        expect(await k.exists(), isFalse);
        kc.put(null, pickleKeyName, validKeyB);
        expect(await k.exists(), isTrue);
        kc.items.clear();
        kc.put(cryptoGroup, pickleKeyName, validKeyA);
        expect(await k.exists(), isTrue);
        expect(kc.writes(), isEmpty);
      },
    );

    test('delete clears the key in both groups', () async {
      kc.put(cryptoGroup, pickleKeyName, validKeyA);
      kc.put(null, pickleKeyName, validKeyB);
      await PickleKey.inGroup(cryptoGroup).delete();
      expect(kc.get(cryptoGroup, pickleKeyName), isNull);
      expect(kc.get(null, pickleKeyName), isNull);
    });
  });
}
