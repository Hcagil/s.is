// Delivery from a push handled in the background (Android, FCM). Written
// from the contract, not the code: a chat push that reaches onBackgroundPush
// while SIS is in the background or closed reports delivery for its chat,
// so the sender's one tick becomes two without the app being opened.
//
// Seam the fix adds in lib/features/notifications/data/firebase_push_source.dart:
//   abstract interface class BackgroundDelivery {
//     Future<String?> savedUserId(); // the saved session's user, or null
//     Future<void> markDelivered(String conversationId); // mark_delivered(conv, null)
//   }
//   @visibleForTesting BackgroundDelivery backgroundDelivery; // real default
// Rules: one awaited call for a chat push whose user_id is the saved user;
// none for a reaction push, a push without conversation_id, no saved session
// or another member's push; an error in either call never escapes and the
// push still ends in a terminal receipt.
// Not covered here (follow-ups): iPhone with the app closed (the
// Notification Service Extension) and phones without Google push.

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

class _FakeDelivery implements BackgroundDelivery {
  String? user = 'member-a';
  Object? userThrows;
  Object? markThrows;
  final calls = <String>[];

  @override
  Future<String?> savedUserId() async {
    if (userThrows != null) throw userThrows!;
    return user;
  }

  @override
  Future<void> markDelivered(String conversationId) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (markThrows != null) throw markThrows!;
    calls.add(conversationId);
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

  late _FakeDelivery fake;
  final original = backgroundDelivery;
  setUp(() {
    fake = _FakeDelivery();
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

  test('1. chat push delivered once', () async {
    disk.values['flutter.sis.push_arrival.$_msg'] = '1700000000123,high,high,n';
    final receipts = await run(makePush({}));
    expect(fake.calls, ['c-chat-one']);
    expect([for (final r in receipts) r['stage']], ['received', 'shown']);
  });

  test('2. not drawn natively: still reported once', () async {
    await run(makePush({}));
    expect(fake.calls, ['c-chat-one']);
  });

  test('3. reaction push no delivery', () async {
    await run(makePush({'kind': 'reaction', 'reactor_id': 'member-b'}));
    expect(fake.calls, isEmpty);
  });

  test('4. push without conversation_id no delivery', () async {
    await run(
      RemoteMessage(
        data: {
          'user_id': 'member-a',
          'title': _title,
          'body': _body,
          'message_id': _msg,
        },
      ),
    );
    expect(fake.calls, isEmpty);
  });

  test('5. no saved session no delivery', () async {
    disk.values['flutter.sis.push_arrival.$_msg'] = '1700000000123,high,high,n';
    fake.user = null;
    final receipts = await run(makePush({}));
    expect(fake.calls, isEmpty);
    expect(receipts.last['stage'], 'shown');
  });

  test('6. push for another member no delivery', () async {
    await run(makePush({'user_id': 'member-x'}));
    expect(fake.calls, isEmpty);
  });

  test('7. savedUserId throws StateError', () async {
    fake.userThrows = StateError('oops');
    await run(makePush({}));
    expect(fake.calls, isEmpty);
  });

  test('8. markDelivered throws StateError', () async {
    disk.values['flutter.sis.push_arrival.$_msg'] = '1700000000123,high,high,n';
    fake.markThrows = StateError('oops');
    final receipts = await run(makePush({}));
    final stages = [for (final r in receipts) r['stage']];
    expect(stages.first, 'received');
    expect(stages.length, 2, reason: '$stages');
    expect(['shown', 'error'], contains(stages.last));
  });
}
