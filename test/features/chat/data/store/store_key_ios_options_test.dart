// StoreKey's keychain options on iOS: the key must be readable after the
// first unlock and never leave this device (no iCloud Keychain, no backup
// restore to another phone). Observed on the plugin's method channel, the
// way the real iOS plugin receives them.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/store_key.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, String> kept;

  setUp(() {
    calls = [];
    kept = {};
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          final args = call.arguments as Map;
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return kept[key];
            case 'write':
              kept[key!] = args['value'] as String;
              return null;
            case 'delete':
              kept.remove(key);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('read, write and delete use first_unlock_this_device', () async {
    const k = StoreKey();
    final key = await k.loadOrCreate();
    expect(kept['sis.store.key'], key);
    await k.delete();
    expect(kept, isEmpty);

    final byMethod = <String, List<MethodCall>>{};
    for (final c in calls) {
      (byMethod[c.method] ??= []).add(c);
    }
    expect(byMethod.keys, containsAll(['read', 'write', 'delete']));
    for (final c in calls) {
      final options = (c.arguments as Map)['options'] as Map;
      expect(
        options['accessibility'],
        'first_unlock_this_device',
        reason: '${c.method} options: $options',
      );
    }
  });
}
