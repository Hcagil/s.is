@Tags(['integration'])
library;

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
      final store = AdminKeyStore();
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

      final r = await repo.confirmLink();

      final keys = await store.load();
      expect(
        keys?.pinned,
        isNull,
        reason: 'a key whose code was not shown must never be pinned',
      );
      expect(r, isA<Ok<AdminStatus>>());
      expect((r as Ok<AdminStatus>).value.phase, AdminLinkPhase.changed);
    },
  );
}
