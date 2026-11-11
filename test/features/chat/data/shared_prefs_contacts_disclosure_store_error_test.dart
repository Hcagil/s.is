// Tests for SharedPrefsContactsDisclosureStore error handling
// Ensures storage errors are logged and swallowed as per contract.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/shared_prefs_contacts_disclosure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/shared_preferences',
  );

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async =>
              throw PlatformException(code: 'disk', message: 'storage broken'),
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('storage error: accepted reports false instead of throwing', () async {
    final store = SharedPrefsContactsDisclosureStore(() => 'u1');
    expect(await store.accepted(), isFalse);
  });

  test('storage error: accept completes without throwing', () async {
    final store = SharedPrefsContactsDisclosureStore(() => 'u1');
    await expectLater(store.accept(), completes);
  });

  test('storage error: accepted still false after a failed accept', () async {
    final store = SharedPrefsContactsDisclosureStore(() => 'u1');
    await store.accept();
    expect(await store.accepted(), isFalse);
  });
}
