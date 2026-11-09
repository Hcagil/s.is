// The platform side of flutter_secure_storage on its real method channel,
// for tests that need a phone storage ERROR (Android Keystore / iOS keychain
// answering with a PlatformException) rather than a missing value. Items are
// kept per iOS access group (`groupId` option; Android has none, so all
// Android items share the null group). Every call is recorded with its
// options, so a test can check the options the plugin received and that no
// write or delete happened. Written from the plugin's channel contract.
//
// Only works in a test file that never calls
// FlutterSecureStorage.setMockInitialValues (that swaps the channel out).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

typedef SecureCall = ({
  String method,
  String? group,
  String? key,
  Map<Object?, Object?> options,
});

class SecureChannelFake {
  /// group (null = default / Android) -> key -> value.
  final items = <String?, Map<String, String>>{};
  final calls = <SecureCall>[];

  /// When it returns true for a reading call (read, containsKey, readAll),
  /// that call fails the way a broken Keystore entry does.
  bool Function(String? group, String? key) failRead = (_, _) => false;

  void put(String? group, String key, String value) =>
      (items[group] ??= {})[key] = value;
  String? get(String? group, String key) => items[group]?[key];

  Iterable<SecureCall> get changes =>
      calls.where((c) => c.method == 'write' || c.method.startsWith('delete'));

  /// Installs it for the current test, on [platform].
  void install({TargetPlatform platform = TargetPlatform.android}) {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = platform;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final options = (args['options'] as Map?) ?? const {};
      final group = options['groupId'] as String?;
      final key = args['key'] as String?;
      calls.add((
        method: call.method,
        group: group,
        key: key,
        options: Map.of(options),
      ));
      // Never a microtask-only answer: a real platform call crosses a hop.
      await Future<void>.delayed(Duration.zero);
      switch (call.method) {
        case 'read' || 'containsKey' || 'readAll':
          if (failRead(group, key)) {
            throw PlatformException(
              code: 'Exception',
              message: 'javax.crypto.AEADBadTagException',
            );
          }
          if (call.method == 'read') return items[group]?[key];
          if (call.method == 'containsKey') {
            return items[group]?.containsKey(key) ?? false;
          }
          return Map.of(items[group] ?? const {});
        case 'write':
          (items[group] ??= {})[key!] = args['value'] as String;
          return null;
        case 'delete':
          items[group]?.remove(key);
          return null;
        case 'deleteAll':
          items[group]?.clear();
          return null;
      }
      throw MissingPluginException(call.method);
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      m.setMockMethodCallHandler(_channel, null);
    });
  }
}
