@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/crypto/rust/api/admin_view_crypto.dart' as crypto;
import 'package:sis/data/crypto/rust/frb_generated.dart';
import 'package:sis/features/admin_panels/data/admin_bytes.dart';
import 'package:sis/features/admin_panels/data/admin_key_store.dart';
import 'package:sis/features/admin_panels/data/supabase_admin_panels_repository.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _pw = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final c = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await c.auth.signInWithPassword(email: email, password: _pw);
  expect(await c.rpc('activate_session'), isTrue);
  return c;
}

late SupabaseClient owner;
late SupabaseClient bridge;

SupabaseAdminPanelsRepository _repoOn(SupabaseClient c, AdminKeyStore store) =>
    SupabaseAdminPanelsRepository(c, store);

Future<int> _bridgeSetKey(List<int> pub) async => await bridge.rpc(
  'admin_view_bridge_set_key',
  params: {'p_pub': byteaParam(pub)},
) as int;

Future<int> _bridgePut(int epoch, int seq, List<int> wire) async =>
    await bridge.rpc(
      'admin_view_bridge_put',
      params: {'p_epoch': epoch, 'p_seq': seq, 'p_body': byteaParam(wire)},
    ) as int;

Future<List<Map<String, dynamic>>> _bridgeTake() async => ((await bridge.rpc(
  'admin_view_bridge_take',
  params: {'p_after_id': 0},
)) as List).cast<Map<String, dynamic>>();

class _Phone {
  _Phone(this.repo, this.store, this.b, this.phonePub, this.epoch);
  final SupabaseAdminPanelsRepository repo;
  final AdminKeyStore store;
  final crypto.AdminViewKeyPair b; // the simulated bridge's key pair
  final List<int> phonePub;
  final int epoch;
}

/// A fresh phone linked with a fresh simulated bridge key.
Future<_Phone> _link() async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = AdminKeyStore();
  final repo = _repoOn(owner, store);
  expect(await repo.startLink(), isA<Ok<AdminStatus>>());
  final phonePub = (await store.load())!.public;
  final b = crypto.adminViewGenerateKeypair();
  await _bridgeSetKey(b.public);
  final st = ((await repo.status()) as Ok<AdminStatus?>).value!;
  expect(st.phase, AdminLinkPhase.confirm);
  expect(st.code, hasLength(60));
  expect(
    st.code,
    crypto.adminViewCode(phonePublic: phonePub, computerPublic: b.public),
  );
  final done = ((await repo.confirmLink(st.code!)) as Ok<AdminStatus>).value;
  expect(done.phase, AdminLinkPhase.linked);
  return _Phone(repo, store, b, phonePub, done.epoch);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    HttpOverrides.global =
        null; // the test binding fakes HTTP; these tests need the real network
    await RustLib.init();
    owner = await _signedIn('avowner@sis.test');
    bridge = await _signedIn('avbridge@sis.test');
  });
  tearDownAll(() async {
    await owner.dispose();
    await bridge.dispose();
  });

  test('link: the keys meet, the code matches, confirm pins', () async {
    final p = await _link();
    final state = await bridge.rpc('admin_view_bridge_state') as List;
    final phonePub = byteaBytes(state[0]['phone_pub'])!;
    expect(phonePub, equals(p.phonePub));
    final keys = await p.store.load();
    expect(keys!.pinned, equals(p.b.public));
    expect(keys.pinnedEpoch, equals(p.epoch));
    expect(p.epoch, greaterThan(0));
  });

  test('round trip down: bridge puts, phone fetches and opens', () async {
    final p = await _link();
    final wire1 = crypto.adminViewSeal(
      mySecret: p.b.secret,
      peerPublic: p.phonePub,
      dir: 0,
      epoch: p.epoch,
      seq: BigInt.one,
      plaintext: utf8.encode('{"t":"items","cursor":7,"items":[]}'),
    );
    await _bridgePut(p.epoch, 1, wire1);
    final r1 = await p.repo.fetch(0);
    expect(r1, isA<Ok<List<AdminRow>>>());
    final rows1 = (r1 as Ok<List<AdminRow>>).value;
    expect(rows1.length, 1);
    final row1 = rows1[0];
    expect(row1.epoch, p.epoch);
    expect(row1.seq, 1);
    expect(row1.message, isA<AdminDelta>());
    expect((row1.message as AdminDelta).cursor, 7);

    final wire2 = crypto.adminViewSeal(
      mySecret: p.b.secret,
      peerPublic: p.phonePub,
      dir: 0,
      epoch: p.epoch,
      seq: BigInt.from(2),
      plaintext: utf8.encode('{"t":"items","cursor":8,"items":[]}'),
    );
    await _bridgePut(p.epoch, 2, wire2);
    final r2 = await p.repo.fetch(row1.id);
    expect(r2, isA<Ok<List<AdminRow>>>());
    final rows2 = (r2 as Ok<List<AdminRow>>).value;
    expect(rows2.length, 1);
    final row2 = rows2[0];
    expect(row2.epoch, p.epoch);
    expect(row2.seq, 2);
    expect((row2.message as AdminDelta).cursor, 8);

    final wrongKey = crypto.adminViewGenerateKeypair();
    final wire3 = crypto.adminViewSeal(
      mySecret: wrongKey.secret,
      peerPublic: p.phonePub,
      dir: 0,
      epoch: p.epoch,
      seq: BigInt.from(3),
      plaintext: utf8.encode('{"t":"items","cursor":9,"items":[]}'),
    );
    await _bridgePut(p.epoch, 3, wire3);
    final r3 = await p.repo.fetch(row2.id);
    expect(r3, isA<Ok<List<AdminRow>>>());
    final rows3 = (r3 as Ok<List<AdminRow>>).value;
    expect(rows3.length, 1);
    expect(rows3[0].message, isNull);
  });

  test('round trip up: phone sends, bridge takes and opens, ack', () async {
    final p = await _link();
    final r1 = await p.repo.send({'t': 'talk', 'text': 'hello admin view'});
    expect(r1, isA<Ok<AdminSentRef?>>());
    final sent1 = (r1 as Ok<AdminSentRef?>).value!;
    expect(sent1.epoch, p.epoch);
    expect(sent1.upSeq, 1);

    final r2 = await p.repo.send({
      't': 'talk',
      'text': 'hello admin view again',
    });
    expect(r2, isA<Ok<AdminSentRef?>>());
    final sent2 = (r2 as Ok<AdminSentRef?>).value!;
    expect(sent2.upSeq, 2);

    final rows = await _bridgeTake();
    expect(rows.length, 2);
    expect(rows[0]['seq'], 1);
    expect(rows[0]['epoch'], p.epoch);
    expect(rows[1]['seq'], 2);
    expect(rows[1]['epoch'], p.epoch);

    final plain = crypto.adminViewOpen(
      mySecret: p.b.secret,
      peerPublic: p.phonePub,
      dir: 1,
      epoch: p.epoch,
      seq: BigInt.from(1),
      wire: byteaBytes(rows[0]['body'])!,
    );
    expect(
      jsonDecode(utf8.decode(plain)),
      equals({'t': 'talk', 'text': 'hello admin view'}),
    );

    final ack = await bridge.rpc(
      'admin_view_bridge_ack',
      params: {
        'p_ids': [rows[0]['id'], rows[1]['id']],
      },
    ) as int;
    expect(ack, 2);
    expect(await _bridgeTake(), isEmpty);
  });

  test(
    'the computer key changed: status is changed, send and fetch are refused',
    () async {
      final p = await _link();
      final newKey = crypto.adminViewGenerateKeypair();
      await _bridgeSetKey(newKey.public);
      final status = await p.repo.status();
      expect(status, isA<Ok<AdminStatus?>>());
      final st = (status as Ok<AdminStatus?>).value!;
      expect(st.phase, AdminLinkPhase.changed);
      expect(st.code, isNotNull);

      final rSend = await p.repo.send({'t': 'talk', 'text': 'x'});
      expect(rSend, isA<Err<AdminSentRef?>>());
      expect((rSend as Err).failure, isA<DeniedFailure>());

      final rFetch = await p.repo.fetch(0);
      expect(rFetch, isA<Err<List<AdminRow>>>());
      expect((rFetch as Err).failure, isA<DeniedFailure>());

      expect(await _bridgeTake(), isEmpty);
    },
  );

  test('a 22023 on send deletes the phone keys', () async {
    final p = await _link();
    await p.repo.send({'t': 'talk', 'text': 'first'});
    await p.repo.send({'t': 'talk', 'text': 'second'});
    final k = (await p.store.load())!;
    await p.store.save(k.copyWith(upEpoch: p.epoch, upSeq: 0));
    final r = await p.repo.send({'t': 'talk', 'text': 'third'});
    expect(r, isA<Err<AdminSentRef?>>());
    expect((r as Err).failure, isA<DeniedFailure>());
    expect(await p.store.load(), isNull);
  });

  test('a member who is not the owner gets no status', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final repo = _repoOn(bridge, AdminKeyStore());
    final status = await repo.status();
    expect(status, isA<Ok<AdminStatus?>>());
    expect((status as Ok<AdminStatus?>).value, isNull);
  });
}
