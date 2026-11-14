// Receipt order of the background push (card gate fix)

import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/push_receipt_log.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

class _OrderFake implements BackgroundDelivery {
  bool hang = false;
  List<Object?>? stagesAtCall;
  final calls = <String>[];

  @override
  Future<String?> savedUserId() async => 'member-a';

  @override
  Future<void> markDelivered(String conversationId) async {
    calls.add(conversationId);
    stagesAtCall = [for (final r in await PushReceiptLog.pending()) r['stage']];
    if (hang) await Completer<void>().future;
  }
}

const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';
const _chat = 'c-chat-one';
const _title = 'Test Person';
const _body = 'hello';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  late Directory support;
  late Directory cache;
  void newIsolate() => SharedPreferences.resetStatic();
  Future<Object?> paths(MethodCall call) async => switch (call.method) {
    'getApplicationSupportDirectory' => support.path,
    'getApplicationCacheDirectory' => cache.path,
    _ => throw MissingPluginException(call.method),
  };
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    support = await Directory.systemTemp.createTemp('sis-support-');
    cache = await Directory.systemTemp.createTemp('sis-cache-');
    messenger.setMockMethodCallHandler(Shade.channel, shade.handle);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    messenger.setMockMethodCallHandler(_pathChannel, paths);
    newIsolate();
    await LocalPushDisplay.init();
    await LocalPushDisplay.forUser('member-a');
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    await support.delete(recursive: true);
    await cache.delete(recursive: true);
  });

  late _OrderFake fake;
  final original = backgroundDelivery;
  setUp(() {
    fake = _OrderFake();
    backgroundDelivery = fake;
  });
  tearDownAll(() {
    backgroundDelivery = original;
  });

  Future<List<Map<String, Object?>>> run(RemoteMessage m) async {
    newIsolate();
    await PushReceiptLog.clear();
    newIsolate();
    await onBackgroundPush(m);
    newIsolate();
    return PushReceiptLog.pending();
  }

  RemoteMessage makePush(Map<String, String> extra) {
    final data = {
      'user_id': 'member-a',
      'conversation_id': _chat,
      'title': _title,
      'body': _body,
      'message_id': _msg,
    }..addAll(extra);
    return RemoteMessage(data: data);
  }

  test('terminal receipt exists when delivered report starts: shown', () async {
    disk.values['flutter.sis.push_arrival.$_msg'] = '1700000000123,high,high,n';
    await run(makePush({}));
    expect(fake.calls, ['c-chat-one']);
    expect(fake.stagesAtCall!.last, 'shown');
  });

  test('... dropped:not_drawn', () async {
    await run(makePush({}));
    expect(fake.stagesAtCall!.last, 'dropped:not_drawn');
  });

  test('... dropped:has_notification', () async {
    await run(
      RemoteMessage(
        data: {
          'user_id': 'member-a',
          'conversation_id': _chat,
          'title': _title,
          'body': _body,
          'message_id': _msg,
        },
        notification: const RemoteNotification(title: 't', body: 'b'),
      ),
    );
    expect(fake.stagesAtCall!.last, 'dropped:has_notification');
  });

  test(
    'a delivered report that never completes: receipt kept, push ends in about 5 s',
    timeout: const Timeout(Duration(seconds: 25)),
    () async {
      fake.hang = true;
      disk.values['flutter.sis.push_arrival.$_msg'] =
          '1700000000123,high,high,n';
      final sw = Stopwatch()..start();
      final receipts = await run(makePush({}))
          .timeout(const Duration(seconds: 12));
      expect(sw.elapsed, lessThan(const Duration(seconds: 9)));
      expect(sw.elapsed, greaterThan(const Duration(seconds: 3)));
      expect(receipts.last['stage'], 'shown');
    },
  );
}
