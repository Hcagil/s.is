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

// --- GatedStorage and helper copied verbatim from admin_view_key_races_test.dart ---

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
    'confirmLink refuses a computer key that changed after the code was shown',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = GatedStorage();
      final store = AdminKeyStore(storage);
      final repo = _repoOn(owner, store);
      expect(await repo.startLink(), isA<Ok<AdminStatus>>());
      final phonePub = (await store.load())!.public;

      final shown = crypto.adminViewGenerateKeypair();
      await _bridgeSetKey(shown.public);

      final st = ((await repo.status()) as Ok<AdminStatus?>).value!;
      expect(st.phase, AdminLinkPhase.confirm);
      expect(
        st.code,
        crypto.adminViewCode(
          phonePublic: phonePub,
          computerPublic: shown.public,
        ),
      );

      final swapped = crypto.adminViewGenerateKeypair();
      await _bridgeSetKey(swapped.public);

      final r = await repo.confirmLink(st.code!);

      final keys = await store.load();
      expect(
        keys?.pinned,
        isNull,
        reason: 'a key whose code was not shown must never be pinned',
      );
      expect(r, isA<Ok<AdminStatus>>());
      expect((r as Ok<AdminStatus>).value.phase, AdminLinkPhase.changed);
      expect(
        r.value.code,
        crypto.adminViewCode(
          phonePublic: phonePub,
          computerPublic: swapped.public,
        ),
      );
    },
  );

  test('a status poll in flight when confirm starts cannot make confirm pin a key whose code was not shown', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = GatedStorage();
    final store = AdminKeyStore(storage);
    final repo = _repoOn(owner, store);
    expect(await repo.startLink(), isA<Ok<AdminStatus>>());
    final phonePub = (await store.load())!.public;

    final a = crypto.adminViewGenerateKeypair();
    await _bridgeSetKey(a.public);
    final st = ((await repo.status()) as Ok<AdminStatus?>).value!;
    expect(st.phase, AdminLinkPhase.confirm);
    final codeA = st.code!;

    final b = crypto.adminViewGenerateKeypair();
    await _bridgeSetKey(b.public);

    storage.arm(onRead: true); // the confirm's first key read waits
    final confirm = repo.confirmLink(codeA);
    await _waitCaught(storage);
    // a status poll that started at the same time finishes now and sees key B
    await repo.status().timeout(const Duration(seconds: 20));
    storage.release();
    final r = await confirm.timeout(const Duration(seconds: 20));

    expect(r, isA<Ok<AdminStatus>>());
    final status = r as Ok<AdminStatus>;
    expect(status.value.phase, AdminLinkPhase.changed);
    expect(
      status.value.code,
      crypto.adminViewCode(phonePublic: phonePub, computerPublic: b.public),
    );
    final keys = await store.load();
    expect(
      keys?.pinned,
      isNull,
      reason: 'nothing pinned: code A was shown, key B is on the server',
    );
  });

  test(
    'confirmLink with the code of the key still on the server pins that key',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = GatedStorage();
      final store = AdminKeyStore(storage);
      final repo = _repoOn(owner, store);
      expect(await repo.startLink(), isA<Ok<AdminStatus>>());
      final a = crypto.adminViewGenerateKeypair();
      await _bridgeSetKey(a.public);
      final st = ((await repo.status()) as Ok<AdminStatus?>).value!;
      expect(st.phase, AdminLinkPhase.confirm);

      final r = await repo.confirmLink(st.code!);
      expect(r, isA<Ok<AdminStatus>>());
      final status = r as Ok<AdminStatus>;
      expect(status.value.phase, AdminLinkPhase.linked);
      final keys = await store.load();
      expect(
        keys?.pinned,
        equals(a.public),
        reason: 'the key that was shown should be pinned',
      );
    },
  );
}
