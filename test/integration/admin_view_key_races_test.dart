@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/crypto/rust/api/admin_view_crypto.dart' as crypto;
import 'package:sis/data/crypto/rust/frb_generated.dart';
import 'package:sis/features/admin_panels/data/admin_bytes.dart';
import 'package:sis/features/admin_panels/data/admin_key_store.dart';
import 'package:sis/features/admin_panels/data/supabase_admin_panels_repository.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

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

class GatedStorage extends FlutterSecureStorage {
  GatedStorage() : super();
  final Map<String, String> _m = {};
  Completer<void>? _gate;
  bool _gateOnRead = true;
  Completer<void> caught = Completer<void>();

  /// The next read (or write when !onRead) that arrives waits until release().
  void arm({required bool onRead}) {
    _gate = Completer<void>();
    _gateOnRead = onRead;
    caught = Completer<void>();
  }

  void release() {
    _gate?.complete();
  }

  Future<void> _maybeWait(bool isRead) async {
    final g = _gate;
    if (g != null && !caught.isCompleted && isRead == _gateOnRead) {
      caught.complete();
      await g.future;
    }
  }

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
    final v = _m[key]; // the value is taken BEFORE waiting, like a real read that returned old data
    await _maybeWait(true);
    return v;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await _maybeWait(false);
    if (value == null) {
      _m.remove(key);
    } else {
      _m[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _m.remove(key);
  }
}

Future<void> _waitCaught(GatedStorage s) =>
    s.caught.future.timeout(const Duration(seconds: 5), onTimeout: () {});

Future<
  ({
    SupabaseAdminPanelsRepository repo,
    AdminKeyStore store,
    GatedStorage storage,
    int epoch,
  })
>
_linked() async {
  final storage = GatedStorage();
  final store = AdminKeyStore(storage);
  final repo = _repoOn(owner, store);
  expect(await repo.startLink(), isA<Ok<AdminStatus>>());
  final b = crypto.adminViewGenerateKeypair();
  await _bridgeSetKey(b.public);
  final st = ((await repo.status()) as Ok<AdminStatus?>).value!;
  expect(st.phase, AdminLinkPhase.confirm);
  final done = ((await repo.confirmLink(st.code!)) as Ok<AdminStatus>).value;
  expect(done.phase, AdminLinkPhase.linked);
  return (repo: repo, store: store, storage: storage, epoch: done.epoch);
}

class FailingStateClient extends http.BaseClient {
  FailingStateClient(this._inner);
  final http.Client _inner;
  bool failState = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (failState && request.url.path.endsWith('/admin_view_state')) {
      throw const SocketException('network down');
    }
    return _inner.send(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    HttpOverrides.global = null;
    await RustLib.init();
    owner = await _signedIn('avowner@sis.test');
    bridge = await _signedIn('avbridge@sis.test');
  });
  tearDownAll(() async {
    await owner.dispose();
    await bridge.dispose();
  });

  test(
    'two sends at the same time get distinct up seqs and keep the key',
    () async {
      final p = await _linked();
      p.storage.arm(
        onRead: false,
      ); // the first send's save before the server call waits
      final a = p.repo.send({'t': 'talk', 'text': 'a'});
      await _waitCaught(p.storage);
      final b = p.repo.send({
        't': 'talk',
        'text': 'b',
      }); // starts while the first is mid-flight
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      p.storage.release();
      final rs = [await a, await b];
      expect(rs[0], isA<Ok<AdminSentRef?>>());
      expect(rs[1], isA<Ok<AdminSentRef?>>());
      final seqs = rs.map((r) => (r as Ok<AdminSentRef?>).value!.upSeq).toSet();
      expect(seqs, {1, 2});
      expect(
        await p.store.load(),
        isNotNull,
        reason: 'a racing send must not delete the key',
      );
    },
  );

  test(
    'a down-seq save during a send cannot lower the stored up seq',
    () async {
      final p = await _linked();
      p.storage.arm(onRead: true);
      final down = p.repo.saveLastDownSeq(p.epoch, 5);
      await _waitCaught(p.storage);
      final send = p.repo.send({'t': 'talk', 'text': 'x'});
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      p.storage.release();
      await down;
      final r = await send;
      expect(r, isA<Ok<AdminSentRef?>>());
      final k = (await p.store.load())!;
      expect(
        k.upSeq,
        1,
        reason: 'the stale down save must not roll the up seq back',
      );
      expect(k.downSeq, 5);
    },
  );

  test('a server epoch change between the link check and the send does not delete the phone key', () async {
    final p = await _linked();
    final before = (await p.store.load())!.public;
    p.storage.arm(onRead: false);
    final send = p.repo.send({'t': 'talk', 'text': 'x'});
    await _waitCaught(p.storage);
    await _bridgeSetKey(crypto.adminViewGenerateKeypair().public);
    p.storage.release();
    final r = await send;
    expect(r, isA<Err<AdminSentRef?>>());
    final k = await p.store.load();
    expect(
      k,
      isNotNull,
      reason: 'the phone key is still the one on the server, so it must not be deleted',
    );
    expect(k!.public, before);
  });

  test('a failed state read after a 22023 keeps the phone key and returns the failure', () async {
    final http1 = FailingStateClient(http.Client());
    final c = SupabaseClient(
      _url,
      _key,
      httpClient: http1,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    await c.auth.signInWithPassword(email: 'avowner@sis.test', password: _pw);
    expect(await c.rpc('activate_session'), isTrue);
    final storage = GatedStorage();
    final store = AdminKeyStore(storage);
    final repo = _repoOn(c, store);
    expect(await repo.startLink(), isA<Ok<AdminStatus>>());
    await _bridgeSetKey(crypto.adminViewGenerateKeypair().public);
    final st = ((await repo.status()) as Ok<AdminStatus?>).value!;
    final done = ((await repo.confirmLink(st.code!)) as Ok<AdminStatus>).value;
    expect(done.phase, AdminLinkPhase.linked);
    final before = (await store.load())!.public;
    storage.arm(
      onRead: false,
    ); // the send's save, right before the server call, waits
    final send = repo.send({'t': 'talk', 'text': 'x'});
    await _waitCaught(storage);
    await _bridgeSetKey(
      crypto.adminViewGenerateKeypair().public,
    ); // epoch changes: the server answers 22023
    http1.failState =
        true; // the follow-up state read after the 22023 now fails
    storage.release();
    final r = await send;
    expect(r, isA<Err<AdminSentRef?>>());
    final k = await store.load();
    expect(k, isNotNull, reason: 'a failed state read must not delete the key');
    expect(k!.public, before);
    await c.dispose();
  });
}
