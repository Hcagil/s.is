// The on-phone store when its key read throws (a broken Keystore entry):
// DriftMessageStore wired as main.dart wires it (key: StoreKey.loadOrCreate,
// deleteKey: StoreKey.delete), over a REAL SQLite3 Multiple Ciphers file and
// the secure-storage plugin's real method channel
// (test/support/secure_channel_fake.dart).
// Contract: the failed open is not kept (the next call opens again and finds
// every row), the file and the key are never touched by the failure, and a
// throwing cold-start prefetch is harmless. Written from the contract.
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/store_key.dart';

import '../../../../support/secure_channel_fake.dart';
import 'store_harness.dart' show msg;

void main() {
  late SecureChannelFake kc;
  late File file;
  var deleteKeyCalls = 0;

  setUp(() async {
    kc = SecureChannelFake()..install();
    DriftMessageStore.resetPrefetchForTest();
    addTearDown(DriftMessageStore.resetPrefetchForTest);
    final dir = await Directory.systemTemp.createTemp('sis-keyread-');
    addTearDown(() => dir.delete(recursive: true));
    file = File(p.join(dir.path, 'sis_store.sqlite'));
    deleteKeyCalls = 0;
  });

  DriftMessageStore open() {
    const key = StoreKey();
    final s = DriftMessageStore(
      ownerId: 'owner-1',
      file: () async => file,
      key: () => key.loadOrCreate(),
      deleteKey: () async {
        deleteKeyCalls++;
        await key.delete();
      },
    );
    addTearDown(s.close);
    return s;
  }

  Future<String> seeded() async {
    final s = open();
    await s.upsertAll([msg('m1', conv: 'c1', body: 'kept')]);
    expect((await s.newest('c1')).map((m) => m.id), ['m1']);
    await s.close();
    return sha256.convert(await file.readAsBytes()).toString();
  }

  test('a key read that throws: the open fails, nothing is erased, and the '
      'next call opens and finds every row', () async {
    final hash = await seeded();
    final key = kc.get(null, 'sis.store.key');
    expect(key, isNotNull, reason: 'fixture: the store key was written');
    final changes = kc.changes.length;

    final s = open();
    kc.failRead = (_, _) => true;
    expect(await s.newest('c1'), isEmpty, reason: 'no key: no rows read');
    await expectLater(
      s.upsertAll([msg('m2', conv: 'c1')]),
      throwsA(anything),
      reason: 'a write without the key fails',
    );
    expect(kc.changes.length, changes, reason: 'no key written or deleted');
    expect(kc.get(null, 'sis.store.key'), key);
    expect(deleteKeyCalls, 0);
    expect(sha256.convert(await file.readAsBytes()).toString(), hash);

    // The storage works again: the SAME store instance opens now.
    kc.failRead = (_, _) => false;
    expect((await s.newest('c1')).map((m) => m.body), ['kept']);
    await s.upsertAll([msg('m3', conv: 'c1', t: 1)]);
    expect((await s.newest('c1')).map((m) => m.id).toSet(), {'m1', 'm3'});
    expect(kc.changes.length, changes);
    expect(deleteKeyCalls, 0);
  });

  test('a cold-start prefetch whose read throws is harmless: the store '
      'opens with the stored key', () async {
    await seeded();
    DriftMessageStore.resetPrefetchForTest();
    final changes = kc.changes.length;
    kc.failRead = (_, _) => true;
    await DriftMessageStore.prefetchKey(() => const StoreKey().peek());
    kc.failRead = (_, _) => false;
    expect((await open().newest('c1')).map((m) => m.body), ['kept']);
    expect(kc.changes.length, changes);
    expect(deleteKeyCalls, 0);
  });
}
