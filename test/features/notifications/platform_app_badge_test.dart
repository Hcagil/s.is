// PlatformAppBadge from its contract, not its code: on Android and iOS it
// sends 'setBadge' with the count (never below 0) over 'sis/notifications';
// elsewhere it sends nothing; a channel error never reaches the caller.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/data/platform_app_badge.dart';

const _channel = MethodChannel('sis/notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answer(Future<Object?>? Function(MethodCall) handler) =>
      messenger.setMockMethodCallHandler(_channel, (call) {
        calls.add(call);
        return handler(call);
      });

  void on(TargetPlatform p) {
    debugDefaultTargetPlatformOverride = p;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  setUp(() {
    calls = [];
    answer((_) async => null);
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('on ${p.name}', () {
      test('sends setBadge with the count', () async {
        on(p);
        await const PlatformAppBadge().set(5);
        expect(calls.map((c) => (c.method, c.arguments)), [('setBadge', 5)]);
      });

      test('sends 0 to clear', () async {
        on(p);
        await const PlatformAppBadge().set(0);
        expect(calls.map((c) => (c.method, c.arguments)), [('setBadge', 0)]);
      });

      test('a negative count is sent as 0', () async {
        on(p);
        await const PlatformAppBadge().set(-3);
        expect(calls.map((c) => (c.method, c.arguments)), [('setBadge', 0)]);
      });

      test('a PlatformException from the channel is swallowed', () async {
        on(p);
        answer((_) async => throw PlatformException(code: 'boom'));
        await expectLater(const PlatformAppBadge().set(2), completes);
        expect(calls, hasLength(1));
      });

      test('no handler (MissingPluginException) is swallowed', () async {
        on(p);
        messenger.setMockMethodCallHandler(_channel, null);
        await expectLater(const PlatformAppBadge().set(2), completes);
      });
    });
  }

  for (final p in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.fuchsia,
  ]) {
    test('on ${p.name} nothing is sent', () async {
      on(p);
      await const PlatformAppBadge().set(4);
      expect(calls, isEmpty);
    });
  }
}
