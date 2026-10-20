// A stand-in for the iOS keychain behind flutter_secure_storage, on the
// plugin's real method channel: items are kept per access group (the
// `groupId` option; none = the app's default group), as the real keychain
// keeps them. Every call is logged in order, so a test can see which group
// was read or written and when.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

class GroupKeychain {
  /// group (null = default group) -> key -> value.
  final items = <String?, Map<String, String>>{};

  /// `read|write|delete|containsKey GROUP KEY` (GROUP is `default` without one), in call order;
  /// a test may add its own markers (e.g. 'setAside').
  final log = <String>[];

  /// When set, every read fails like a locked keychain.
  bool failReads = false;

  void put(String? group, String key, String value) =>
      (items[group] ??= {})[key] = value;
  String? get(String? group, String key) => items[group]?[key];

  List<String> writes() => [
    for (final l in log)
      if (l.startsWith('write ')) l,
  ];

  /// Installs it as the plugin's platform side, with the iOS options, until
  /// the test ends.
  void install() {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final args = call.arguments as Map;
          final options = (args['options'] as Map?) ?? const {};
          final group = options['groupId'] as String?;
          final key = args['key'] as String?;
          log.add('${call.method} ${group ?? 'default'} $key');
          switch (call.method) {
            case 'read':
              if (failReads) {
                throw PlatformException(code: '-25308', message: 'locked');
              }
              return items[group]?[key];
            case 'containsKey':
              return items[group]?.containsKey(key) ?? false;
            case 'write':
              (items[group] ??= {})[key!] = args['value'] as String;
              return null;
            case 'delete':
              items[group]?.remove(key);
              return null;
          }
          throw MissingPluginException(call.method);
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });
  }
}

const storeKeyName = 'sis.store.key';
const pickleKeyName = 'sis.olm.pickle.key';
const cryptoGroup = 'TEAM123.com.esd.sis.crypto';
final validKeyA = 'a1' * 32;
final validKeyB = '0f' * 32;
