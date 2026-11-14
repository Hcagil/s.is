// Background delivery gate: the saved session is read only, expiring tokens skip

import 'dart:io';
import 'dart:convert';

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
import 'package:sis/features/notifications/data/background_delivery.dart';

import '../../support/secure_channel_fake.dart';
import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

const _sessionKey = 'sis.supabase.session';
const _arrival = '1700000000123,high,high,n';
String _session({required int expiresInSeconds, String user = 'member-a'}) =>
    jsonEncode({
      'access_token': 'tok',
      'expires_at':
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresInSeconds,
      'user': {'id': user},
    });

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

  late SecureChannelFake secure;
  final original = backgroundDelivery;
  setUp(() {
    secure = SecureChannelFake()..install();
    backgroundDelivery = const SupabaseBackgroundDelivery();
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

  group('onBackgroundPush leaves the saved session alone', () {
    test('token expired 100 s ago', () async {
      disk.values['flutter.sis.push_arrival.$_msg'] = _arrival;
      secure.put(null, _sessionKey, _session(expiresInSeconds: -100));
      final receipts = await run(makePush({}));
      expect(secure.changes, isEmpty);
      expect(receipts.last['stage'], 'shown');
    });

    test('token expiring in 10 s', () async {
      disk.values['flutter.sis.push_arrival.$_msg'] = _arrival;
      secure.put(null, _sessionKey, _session(expiresInSeconds: 10));
      final receipts = await run(makePush({}));
      expect(secure.changes, isEmpty);
      expect(receipts.last['stage'], 'shown');
    });

    test('token expiring in 29 s', () async {
      disk.values['flutter.sis.push_arrival.$_msg'] = _arrival;
      secure.put(null, _sessionKey, _session(expiresInSeconds: 29));
      final receipts = await run(makePush({}));
      expect(secure.changes, isEmpty);
      expect(receipts.last['stage'], 'shown');
    });

    test('no saved session', () async {
      disk.values['flutter.sis.push_arrival.$_msg'] = _arrival;
      final receipts = await run(makePush({}));
      expect(secure.changes, isEmpty);
      expect(receipts.last['stage'], 'shown');
    });

    test('saved user is another member', () async {
      disk.values['flutter.sis.push_arrival.$_msg'] = _arrival;
      secure.put(
        null,
        _sessionKey,
        _session(expiresInSeconds: 3600, user: 'member-x'),
      );
      final receipts = await run(makePush({}));
      expect(secure.changes, isEmpty);
      expect(receipts.last['stage'], 'shown');
    });

    test('garbage session text', () async {
      disk.values['flutter.sis.push_arrival.$_msg'] = _arrival;
      secure.put(null, _sessionKey, 'not json');
      final receipts = await run(makePush({}));
      expect(secure.changes, isEmpty);
      expect(receipts.last['stage'], 'shown');
    });
  });

  group('markDelivered skips quietly', () {
    test('expired', () async {
      secure.put(null, _sessionKey, _session(expiresInSeconds: -100));
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered('c-chat-one'),
        completes,
      );
      expect(secure.changes, isEmpty);
    });

    test('expiring in 10 s', () async {
      secure.put(null, _sessionKey, _session(expiresInSeconds: 10));
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered('c-chat-one'),
        completes,
      );
      expect(secure.changes, isEmpty);
    });

    test('expiring in 29 s', () async {
      secure.put(null, _sessionKey, _session(expiresInSeconds: 29));
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered('c-chat-one'),
        completes,
      );
      expect(secure.changes, isEmpty);
    });

    test('no saved session', () async {
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered('c-chat-one'),
        completes,
      );
      expect(secure.changes, isEmpty);
    });

    test('empty access token', () async {
      secure.put(
        null,
        _sessionKey,
        jsonEncode({
          'access_token': '',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          'user': {'id': 'member-a'},
        }),
      );
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered('c-chat-one'),
        completes,
      );
      expect(secure.changes, isEmpty);
    });

    test('no expires_at', () async {
      secure.put(
        null,
        _sessionKey,
        jsonEncode({
          'access_token': 'tok',
          'user': {'id': 'member-a'},
        }),
      );
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered('c-chat-one'),
        completes,
      );
      expect(secure.changes, isEmpty);
    });
  });
}
