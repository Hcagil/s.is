// guardLostPickleKey against a REAL SQLite3 Multiple Ciphers store file,
// written by the app's own store (DriftMessageStore + DriftOlmPickleStore) and
// keyed like production; the keychain is test/support/group_keychain.dart on
// the plugin's real channel. Contract: with an olm_account row and the pickle
// key gone from both groups, the store is renamed aside (never deleted) and
// the store key forgotten; otherwise, and on any error, nothing changes and
// nothing is thrown.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/pickle_key.dart';
import 'package:sis/features/crypto/data/pickle_key_guard.dart';

import '../../../support/drift_stores.dart';
import '../../../support/group_keychain.dart';

final _orphan = RegExp(r'^sis_store\.orphan-\d+\.sqlite(-wal|-shm)?$');

void main() {
  late GroupKeychain kc;
  late Directory dir;
  late File file;

  setUp(() async {
    kc = GroupKeychain()..install();
    dir = await Directory.systemTemp.createTemp('sis-guard-');
    addTearDown(() async {
      await Process.run('chmod', ['-R', 'u+w', dir.path]);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    file = storeFileIn(dir);
  });

  /// A real store file keyed with [key]; with [pickle], the account pickle
  /// row the app writes for its Olm account.
  Future<void> makeStore({required String key, String? pickle}) async {
    final store = driftStore('bob', dir, key);
    final pickles = DriftOlmPickleStore(store);
    if (pickle != null) {
      expect(await pickles.save(pickle), isTrue);
    } else {
      expect(await pickles.load(), isNull); // opens and creates the file
    }
    await store.close();
    expect(file.existsSync(), isTrue);
  }

  /// Every file in the folder with a hash of its bytes, and every keychain item.
  String snapshot() {
    final files = {
      for (final f in dir.listSync().whereType<File>())
        p.basename(f.path): sha256.convert(f.readAsBytesSync()).toString(),
    };
    return jsonEncode({
      'files': Map.fromEntries(
        files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      ),
      'keychain': {
        for (final g in kc.items.entries)
          if (g.value.isNotEmpty) '${g.key}': g.value,
      },
    });
  }

  Future<void> guard({String? group = cryptoGroup}) => guardLostPickleKey(
    group: group,
    file: file,
    storeKey: StoreKey.inGroup(group),
    pickleKey: PickleKey.inGroup(group),
  );

  test(
    'pickles stored, pickle key gone from both groups: the store is set '
    'aside (bytes kept) and the store key forgotten in both groups',
    () async {
      await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      final before = sha256.convert(file.readAsBytesSync()).toString();

      await guard();

      expect(file.existsSync(), isFalse);
      final names = [for (final f in dir.listSync()) p.basename(f.path)];
      expect(names, isNotEmpty);
      expect(names, everyElement(matches(_orphan)), reason: '$names');
      final main = dir.listSync().whereType<File>().firstWhere(
        (f) => p.basename(f.path).endsWith('.sqlite'),
      );
      expect(sha256.convert(main.readAsBytesSync()).toString(), before);
      expect(kc.get(cryptoGroup, storeKeyName), isNull);
      expect(kc.get(null, storeKeyName), isNull);
    },
  );

  test('the store key only in the default group counts as present', () async {
    await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
    kc.put(null, storeKeyName, validKeyA);
    await guard();
    expect(file.existsSync(), isFalse);
    expect(kc.get(null, storeKeyName), isNull);
  });

  test('no account pickle in the store: nothing changes', () async {
    await makeStore(key: validKeyA);
    kc.put(cryptoGroup, storeKeyName, validKeyA);
    final before = snapshot();
    await guard();
    expect(snapshot(), before);
  });

  test('pickle key still in the crypto group: nothing changes', () async {
    await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
    kc.put(cryptoGroup, storeKeyName, validKeyA);
    kc.put(cryptoGroup, pickleKeyName, validKeyB);
    final before = snapshot();
    await guard();
    expect(snapshot(), before);
  });

  test('pickle key only in the default group: nothing changes', () async {
    await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
    kc.put(cryptoGroup, storeKeyName, validKeyA);
    kc.put(null, pickleKeyName, validKeyB);
    final before = snapshot();
    await guard();
    expect(snapshot(), before);
  });

  test(
    'no keychain group (Android, unsigned build): nothing changes',
    () async {
      await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
      kc.put(null, storeKeyName, validKeyA);
      final before = snapshot();
      await guard(group: null);
      expect(snapshot(), before);
    },
  );

  test('no store key saved: nothing changes', () async {
    await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
    final before = snapshot();
    await guard();
    expect(snapshot(), before);
  });

  test('no store file: nothing changes, nothing is made', () async {
    kc.put(cryptoGroup, storeKeyName, validKeyA);
    final before = snapshot();
    await guard();
    expect(snapshot(), before);
    expect(dir.listSync(), isEmpty);
  });

  group('any error: nothing changes, nothing thrown', () {
    test('the saved store key does not open the file', () async {
      await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
      kc.put(cryptoGroup, storeKeyName, validKeyB);
      final before = snapshot();
      await guard();
      expect(snapshot(), before);
    });

    test('the store file is not a database', () async {
      file.writeAsStringSync('not a database at all' * 100);
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      final before = snapshot();
      await guard();
      expect(snapshot(), before);
    });

    test('the keychain cannot be read (locked)', () async {
      await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      kc.failReads = true;
      final before = snapshot();
      await guard();
      expect(snapshot(), before);
    });

    test('the store cannot be renamed: the store key is kept', () async {
      await makeStore(key: validKeyA, pickle: 'ACCOUNT-PICKLE');
      kc.put(cryptoGroup, storeKeyName, validKeyA);
      final before = snapshot();
      await Process.run('chmod', ['a-w', dir.path]);
      await guard();
      await Process.run('chmod', ['u+w', dir.path]);
      expect(snapshot(), before);
      expect(kc.get(cryptoGroup, storeKeyName), validKeyA);
    });
  });
}
