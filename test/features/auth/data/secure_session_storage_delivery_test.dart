// SecureSessionStorage's small delivery item ('sis.push.delivery') for the
// iPhone notification extension, against the secure-storage plugin's real
// method channel on iOS. Contract: the session is stored unchanged; the item
// holds exactly five keys, lives in the crypto group with first-unlock access,
// is never a reason for persistSession to fail, and is removed with the
// session. Written from the contract.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/data/secure_session_storage.dart';

import '../../../support/secure_channel_fake.dart';

const _key = 'sis.supabase.session';
const _deliveryKey = 'sis.push.delivery';
const _crypto = 'TEAM123.com.esd.sis.crypto';
const _session =
    '{"access_token":"tok-1","expires_in":3600,"expires_at":1767225600,"refresh_token":"ref-secret-1","token_type":"bearer","user":{"id":"u-1","email":"ann@mail.test","aud":"authenticated"}}';

SecureSessionStorage _s() => SecureSessionStorage(group: () async => _crypto);

void main() {
  late SecureChannelFake kc;

  setUp(() {
    kc = SecureChannelFake()..install(platform: TargetPlatform.iOS);
  });

  List<SecureCall> writesOf(String key) =>
      kc.calls.where((c) => c.method == 'write' && c.key == key).toList();

  test(
    'persistSession stores the session unchanged in the default group',
    () async {
      await _s().persistSession(_session);
      expect(kc.get(null, _key), _session);
      final w = writesOf(_key);
      expect(w, hasLength(1));
      expect(w.single.group, isNull);
    },
  );

  test('the delivery item holds exactly access_token, expires_at, user_id, url, key', () async {
    await _s().persistSession(_session);
    final raw = kc.get(_crypto, _deliveryKey);
    expect(raw, isNotNull);
    final cfg = RuntimeConfig.fromEnvironment();
    expect(jsonDecode(raw!), {
      'access_token': 'tok-1',
      'expires_at': 1767225600,
      'user_id': 'u-1',
      'url': cfg.supabaseUrl,
      'key': cfg.supabasePublishableKey,
    });
    expect(raw, isNot(contains('ref-secret-1')));
    expect(raw, isNot(contains('mail.test')));
    expect(raw, isNot(contains('authenticated')));
  });

  test(
    'the delivery item goes only to the crypto group, first unlock this device',
    () async {
      await _s().persistSession(_session);
      final w = writesOf(_deliveryKey);
      expect(w, hasLength(1));
      expect(w.single.group, _crypto);
      expect(w.single.options['accessibility'], 'first_unlock_this_device');
    },
  );

  test('a refreshed session replaces the item', () async {
    await _s().persistSession(_session);
    final refreshed = _session
        .replaceAll('tok-1', 'tok-2')
        .replaceAll('1767225600', '1767229200');
    await _s().persistSession(refreshed);
    final raw = kc.get(_crypto, _deliveryKey);
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!);
    expect(decoded['access_token'], 'tok-2');
    expect(decoded['expires_at'], 1767229200);
  });

  test('a refused delivery write does not fail persistSession', () async {
    kc.failWrite = (g, k) => k == _deliveryKey;
    await expectLater(_s().persistSession(_session), completes);
    expect(kc.get(null, _key), _session);
    expect(kc.get(_crypto, _deliveryKey), isNull);
  });

  test('a group lookup that throws does not fail persistSession', () async {
    final s = SecureSessionStorage(
      group: () async => throw PlatformException(code: 'group'),
    );
    await expectLater(s.persistSession(_session), completes);
    expect(kc.get(null, _key), _session);
    expect(writesOf(_deliveryKey), isEmpty);
  });

  for (final bad in [
    'not json',
    '[]',
    '{}',
    '{"access_token":"tok-1"}',
    // no user: nothing names whose item it is
    '{"access_token":"tok-1","expires_at":1767225600}',
    // no expiry: the extension could not tell a dead token
    '{"access_token":"tok-1","user":{"id":"u-1"}}',
  ]) {
    test('malformed session $bad: no delivery item', () async {
      await expectLater(_s().persistSession(bad), completes);
      expect(kc.get(null, _key), bad);
      expect(writesOf(_deliveryKey), isEmpty);
    });
  }

  test('removePersistedSession deletes both items', () async {
    kc.put(null, _key, _session);
    kc.put(_crypto, _deliveryKey, '{"access_token":"tok-1"}');
    await _s().removePersistedSession();
    expect(kc.get(null, _key), isNull);
    expect(kc.get(_crypto, _deliveryKey), isNull);
  });

  test('removePersistedSession: main delete throwing still deletes the delivery item', () async {
    kc.put(null, _key, _session);
    kc.put(_crypto, _deliveryKey, '{"access_token":"tok-1"}');
    kc.failDelete = (g, k) => k == _key;
    try {
      await _s().removePersistedSession();
    } catch (e) {
      // ignore
    }
    expect(kc.get(_crypto, _deliveryKey), isNull);
  });

  test('removePersistedSession: delivery delete throwing still deletes the main key', () async {
    kc.put(null, _key, _session);
    kc.put(_crypto, _deliveryKey, '{"access_token":"tok-1"}');
    kc.failDelete = (g, k) => k == _deliveryKey;
    try {
      await _s().removePersistedSession();
    } catch (e) {
      // ignore
    }
    expect(kc.get(null, _key), isNull);
  });
}
