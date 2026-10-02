// 0.30.7: Android draws a not-high-priority push itself, at once
// (InstantPush.kt); the deferred Dart handler later replaces it in place.
// Written from the contract (docs/DECISIONS.md), not the code.
//
// Two halves:
// - Parity: test/fixtures/instant_push_vectors.json is also read by
//   android/app/src/test/kotlin/com/esd/sis/InstantPushTest.kt. Here the
//   Dart side is held to the same notification ids, group key and per-chat
//   alert resolution, so neither language can drift alone.
// - The seam: the native receiver cannot run here, so its two effects are
//   reproduced as Android leaves them -- its notification sitting in the
//   shade under the conversation's id (on its own channel), and its arrival
//   note "ms,delivered,original,n" in the preferences file -- and the real
//   background handler (onBackgroundPush) runs afterwards, as a fresh isolate
//   does once Doze lets the deferred job start.
//
// The device is the shared fakes in test/support/push_platform.dart.
// Run under TZ=JST-9 (as CI does): receipts carry epoch ms.
import 'dart:convert';
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
import 'package:sis/features/notifications/data/shared_prefs_alert_store.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _owner = 'member-a';
const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';

final _vectors = jsonDecode(
  File('test/fixtures/instant_push_vectors.json').readAsStringSync(),
) as Map<String, Object?>;

/// The arrival note's key, as the Kotlin receiver writes it.
String _arrivalKey(String id) => 'flutter.sis.push_arrival.$id';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  late Directory support;
  late Directory cache;

  void newIsolate() {
    SharedPreferences.resetStatic();
    LocalPushDisplay.resetForTest();
  }

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
    await LocalPushDisplay.forUser(_owner);
  });

  tearDown(() async {
    // A flush still pacing its posts finishes before the next test.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    await support.delete(recursive: true);
    await cache.delete(recursive: true);
  });

  group('parity with InstantPush.kt (shared vectors)', () {
    final ids = (_vectors['ids']! as List).cast<Map<String, Object?>>();

    test('the notification id of each conversation is the shared one, in '
        'the shared group', () async {
      for (final v in ids) {
        final chat = v['conversation_id']! as String;
        expect(
          await LocalPushDisplay.show(
            conversationId: chat,
            title: 'Ann',
            body: 'hi',
          ),
          isTrue,
        );
        expect(shade.childFor(chat)['id'], v['id'], reason: chat);
      }
      expect(shade.groupKeys, {
        _vectors['group_key'],
      }, reason: 'the native draw joins this group');
    });

    final alerts = (_vectors['alerts']! as List).cast<Map<String, Object?>>();
    for (final v in alerts) {
      test('alert resolution: ${v['name']}', () async {
        if (v['defaults'] != null) {
          disk.values['flutter.sis.alert_defaults'] = v['defaults']! as String;
        }
        if (v['chats'] != null) {
          disk.values['flutter.sis.alert_chats'] = v['chats']! as String;
        }
        newIsolate();
        const store = SharedPrefsAlertStore();
        final chats = await store.loadChats();
        final a = resolveAlert(
          await store.loadDefaults(),
          chats[v['conversation_id']] ?? const ChatAlert(),
        );
        expect(a.sound, v['sound'], reason: 'sound');
        expect(a.vibration, v['vibration'], reason: 'vibration');
      });
    }
  });

  group('the deferred Dart handler after the native draw', () {
    const chat = 'c-private-chat';
    final id =
        (_vectors['ids']! as List).cast<Map<String, Object?>>().singleWhere(
              (v) => v['conversation_id'] == chat,
            )['id']!
            as int;

    RemoteMessage message() => RemoteMessage(
      data: {
        'conversation_id': chat,
        'title': 'Zelda',
        'body': 'late but here',
        'message_id': _msg,
        'user_id': _owner,
      },
    );

    /// What InstantPush.kt leaves on the phone when it drew the push: its
    /// notification under the conversation's id on its own channel, and the
    /// arrival note with the drawn flag.
    void nativeDrew() {
      shade.posted[id] = {
        'id': id,
        'title': 'Zelda',
        'body': 'late but here',
        'payload': chat,
        'platformSpecifics': {
          'channelId': 'sis-instant',
          'groupKey': _vectors['group_key'],
        },
      };
      disk.values[_arrivalKey(_msg)] = '1700000000123,?,?,n';
    }

    /// The handler as Doze finally lets it run: a fresh isolate.
    Future<List<Map<String, Object?>>> deferredHandler() async {
      newIsolate();
      await PushReceiptLog.clear();
      newIsolate();
      shade.calls.clear();
      shade.shows.clear();
      await onBackgroundPush(message());
      newIsolate();
      return PushReceiptLog.pending();
    }

    test('replaces the native notification in place: same id, one '
        'notification for the chat, and no second alert', () async {
      nativeDrew();

      final receipts = await deferredHandler();

      expect([for (final r in receipts) r['stage']], ['received', 'shown']);
      final mine = [
        for (final s in shade.shows)
          if (s.n['payload'] == chat) s.n,
      ];
      expect(mine, isNotEmpty, reason: 'Dart drew the full state');
      for (final n in mine) {
        expect(n['id'], id, reason: 'replaced in place');
        final a = Shade.alerting(n);
        expect(
          a.silent || a.onlyAlertOnce,
          isTrue,
          reason: 'the native draw already alerted: $n',
        );
      }
      expect(shade.children.where((n) => n['payload'] == chat), hasLength(1));
      expect(shade.childFor(chat)['id'], id);
      expect(
        shade.calls.where((c) => c == 'cancel' || c == 'cancelAll'),
        isEmpty,
        reason: 'a cancel then post is a new notification, which alerts',
      );
      // Every post in this run, the summary included, stays quiet.
      for (final s in shade.shows) {
        final a = Shade.alerting(s.n);
        expect(a.silent || a.onlyAlertOnce, isTrue, reason: '${s.n}');
      }
    });

    test('the received receipt says fast=native', () async {
      nativeDrew();

      final receipts = await deferredHandler();

      final note = receipts.first['error']! as String;
      expect(note, contains('fast=native'));
      expect(note, contains('native=1700000000123'), reason: note);
      expect(note, contains('prio=?/?'), reason: note);
      expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
    });

    test('a push the native side did not draw (high priority): Dart alerts '
        'as before, no fast=native', () async {
      disk.values[_arrivalKey(_msg)] = '1700000000123,high,high';

      final receipts = await deferredHandler();

      expect([for (final r in receipts) r['stage']], ['received', 'shown']);
      final note = receipts.first['error']! as String;
      expect(note, isNot(contains('fast=')), reason: note);
      final n = shade.childFor(chat);
      expect(n['id'], id);
      expect(Shade.alerting(n).silent, isFalse, reason: 'first draw alerts');
    });

    test('no arrival note at all: Dart alerts as before, no '
        'fast=native', () async {
      final receipts = await deferredHandler();

      final note = receipts.first['error']! as String;
      expect(note, isNot(contains('fast=')), reason: note);
      expect(Shade.alerting(shade.childFor(chat)).silent, isFalse);
    });
  });
}
