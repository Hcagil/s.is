// SecureSessionStorage (where supabase keeps the sign-in session) against the
// secure-storage plugin's real method channel. Contract: Android options turn
// resetOnError off (rest at defaults); a read that throws throws again (never
// taken as "no session", so start-up stops instead of signing out), and
// nothing is written or deleted; a stored value passes through unchanged. Written from the contract.
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/data/secure_session_storage.dart';

import '../../../support/secure_channel_fake.dart';

const _key = 'sis.supabase.session';
const _session = '{"access_token":"tok-1","refresh_token":"ref-1"}';

void main() {
  late SecureChannelFake kc;

  setUp(() {
    kc = SecureChannelFake()..install();
  });

  test('every call uses resetOnError false, other Android options at '
      'defaults', () async {
    const s = SecureSessionStorage();
    await s.persistSession(_session);
    await s.accessToken();
    await s.hasAccessToken();
    await s.removePersistedSession();
    final want = {...const AndroidOptions().toMap(), 'resetOnError': 'false'};
    expect(kc.calls, isNotEmpty);
    for (final c in kc.calls) {
      expect(c.options, want, reason: '${c.method}: ${c.options}');
    }
  });

  test('a stored session passes through', () async {
    kc.put(null, _key, _session);
    const s = SecureSessionStorage();
    expect(await s.accessToken(), _session);
    expect(await s.hasAccessToken(), isTrue);
  });

  test('a read that throws: accessToken throws again, nothing '
      'changed', () async {
    kc.put(null, _key, _session);
    kc.failRead = (_, _) => true;
    await expectLater(
      const SecureSessionStorage().accessToken(),
      throwsA(isA<PlatformException>()),
    );
    expect(kc.changes, isEmpty);
    expect(kc.get(null, _key), _session, reason: 'the session is kept');
  });

  test('a read that throws: hasAccessToken throws again, nothing '
      'changed', () async {
    kc.put(null, _key, _session);
    kc.failRead = (_, _) => true;
    await expectLater(
      const SecureSessionStorage().hasAccessToken(),
      throwsA(isA<PlatformException>()),
    );
    expect(kc.changes, isEmpty);
    expect(kc.get(null, _key), _session);
  });
}
