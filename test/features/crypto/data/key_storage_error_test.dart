// A phone storage error never erases the chat keys: PickleKey (Olm pickle
// key) and StoreKey (on-phone store key) against the secure-storage plugin's
// real method channel (test/support/secure_channel_fake.dart).
// Contract: Android options turn the plugin's "reset everything on a read
// error" off; a read that throws makes loadOrCreate/read/exists/peek throw
// and nothing is written or deleted; a clean "no value" still creates the
// key once; the iOS lost-key guard still throws. Written from the contract.
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/crypto/data/pickle_key.dart';

import '../../../support/secure_channel_fake.dart';

const _pickleName = 'sis.olm.pickle.key';
const _storeName = 'sis.store.key';
const _group = 'TEAM123.com.esd.sis.crypto';
final _hexA = 'a1' * 32;
final _bytesA = List<int>.filled(32, 0xa1);

/// The plugin's Android defaults with only resetOnError turned off.
final _wantAndroid = {
  ...const AndroidOptions().toMap(),
  'resetOnError': 'false',
};

void main() {
  late SecureChannelFake kc;

  setUp(() => kc = SecureChannelFake());

  void everyCallHasAndroidOptions() {
    expect(kc.calls, isNotEmpty);
    for (final c in kc.calls) {
      expect(
        c.options,
        _wantAndroid,
        reason: '${c.method} ${c.key} options: ${c.options}',
      );
    }
  }

  group('1 Android options: resetOnError false, the rest at defaults', () {
    test('fixture: the plugin default would reset on error', () {
      expect(const AndroidOptions().toMap()['resetOnError'], 'true');
    });

    for (final (name, make) in <(String, PickleKey Function())>[
      ('PickleKey()', () => PickleKey()),
      ('PickleKey.inGroup(null)', () => PickleKey.inGroup(null)),
      ('PickleKey.inGroup(group)', () => PickleKey.inGroup(_group)),
    ]) {
      test(name, () async {
        kc.install();
        final k = make();
        await k.loadOrCreate();
        await k.read();
        await k.exists();
        await k.delete();
        everyCallHasAndroidOptions();
      });
    }

    for (final (name, make) in <(String, StoreKey Function())>[
      ('StoreKey()', () => const StoreKey()),
      ('StoreKey.inGroup(null)', () => StoreKey.inGroup(null)),
      ('StoreKey.inGroup(group)', () => StoreKey.inGroup(_group)),
    ]) {
      test(name, () async {
        kc.install();
        final k = make();
        await k.loadOrCreate();
        await k.peek();
        await k.read();
        await k.delete();
        everyCallHasAndroidOptions();
      });
    }
  });

  group('2 loadOrCreate: a throwing read throws, nothing written', () {
    test('PickleKey: the primary read throws', () async {
      kc.install();
      kc.failRead = (_, _) => true;
      await expectLater(PickleKey().loadOrCreate(), throwsA(anything));
      expect(kc.changes, isEmpty);
    });

    test('StoreKey: the primary read throws', () async {
      kc.install();
      kc.failRead = (_, _) => true;
      await expectLater(const StoreKey().loadOrCreate(), throwsA(anything));
      expect(kc.changes, isEmpty);
    });

    test('PickleKey (Android, inGroup null): a stored key that fails to '
        'decrypt is kept, never replaced', () async {
      kc.install();
      kc.put(null, _pickleName, _hexA);
      kc.failRead = (_, key) => key == _pickleName;
      await expectLater(
        PickleKey.inGroup(null).loadOrCreate(),
        throwsA(isA<PlatformException>()),
      );
      expect(kc.changes, isEmpty);
      expect(kc.get(null, _pickleName), _hexA);
    });

    test('PickleKey.inGroup: null in the group, the legacy read throws: '
        'throws, nothing written', () async {
      kc.install(platform: TargetPlatform.iOS);
      kc.failRead = (group, _) => group == null; // only the legacy group
      await expectLater(
        PickleKey.inGroup(_group, hasPickles: () async => false).loadOrCreate(),
        throwsA(anything),
      );
      expect(
        kc.calls.where((c) => c.method == 'read' && c.group == null),
        isNotEmpty,
        reason: 'fixture: the legacy group was read',
      );
      expect(kc.changes, isEmpty);
    });

    test('StoreKey.inGroup: null in the group, the legacy read throws: '
        'throws, nothing written', () async {
      kc.install(platform: TargetPlatform.iOS);
      kc.failRead = (group, _) => group == null;
      await expectLater(
        StoreKey.inGroup(_group).loadOrCreate(),
        throwsA(anything),
      );
      expect(
        kc.calls.where((c) => c.method == 'read' && c.group == null),
        isNotEmpty,
        reason: 'fixture: the legacy group was read',
      );
      expect(kc.changes, isEmpty);
    });

    test('PickleKey: a clean null still creates and writes once', () async {
      kc.install();
      final k = PickleKey();
      final key = await k.loadOrCreate();
      expect(key, hasLength(32));
      expect(kc.changes.map((c) => '${c.method} ${c.key}'), [
        'write $_pickleName',
      ]);
      expect(await k.loadOrCreate(), key);
      expect(kc.changes, hasLength(1));
    });

    test('StoreKey: a clean null still creates and writes once', () async {
      kc.install();
      const k = StoreKey();
      final key = await k.loadOrCreate();
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(kc.changes.map((c) => '${c.method} ${c.key}'), [
        'write $_storeName',
      ]);
      expect(await k.loadOrCreate(), key);
      expect(kc.changes, hasLength(1));
    });

    test('iOS guard: no key in either group but pickles stored: throws, '
        'no new key', () async {
      kc.install(platform: TargetPlatform.iOS);
      await expectLater(
        PickleKey.inGroup(_group, hasPickles: () async => true).loadOrCreate(),
        throwsA(anything),
      );
      expect(kc.changes, isEmpty);
    });
  });

  group('3 read / exists / peek: a throwing read throws, nothing changed', () {
    setUp(() {
      kc.install();
      kc.put(null, _pickleName, _hexA);
      kc.put(null, _storeName, _hexA);
    });

    test('fixture: the same keys read fine without the error', () async {
      expect(await PickleKey().read(), _bytesA);
      expect(await PickleKey().exists(), isTrue);
      expect(await const StoreKey().peek(), _hexA);
      expect(await const StoreKey().read(), _hexA);
    });

    test('PickleKey.read throws', () async {
      kc.failRead = (_, _) => true;
      await expectLater(PickleKey().read(), throwsA(anything));
      expect(kc.changes, isEmpty);
    });

    test('PickleKey.exists throws (never a false "no key")', () async {
      kc.failRead = (_, _) => true;
      await expectLater(PickleKey().exists(), throwsA(anything));
      expect(kc.changes, isEmpty);
    });

    test('StoreKey.peek throws', () async {
      kc.failRead = (_, _) => true;
      await expectLater(const StoreKey().peek(), throwsA(anything));
      expect(kc.changes, isEmpty);
    });

    test('StoreKey.read throws', () async {
      kc.failRead = (_, _) => true;
      await expectLater(const StoreKey().read(), throwsA(anything));
      expect(kc.changes, isEmpty);
      expect(kc.get(null, _storeName), _hexA);
      expect(kc.get(null, _pickleName), _hexA);
    });
  });
}
