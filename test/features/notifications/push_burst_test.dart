// 0.30.4: arrival timing receipts and the iPhone's read-clears. Written
// from the 0.30.4 contract, not the code. (Pacing, sender pictures and the
// alert rule moved to the native drawer in Update 1: PushArrivalReceiverTest
// and NativeDrawTest under android/app/src/test.)
//
// The device fakes (test/support/push_platform.dart) plus, here:
// - the Android native receiver (PushArrivalReceiver.kt), which cannot run
//   here: its write is reproduced exactly as it lands in the preferences
//   file -- key "flutter.sis.push_arrival.<id>", value
//   "ms,delivered,original" plus ",q" while drawing and ",n" once drawn --
//   and written UNDER a live isolate's cached copy, as a native write is.
// - the iPhone's 'sis/notifications' channel (AppDelegate.swift), which
//   cannot run here either: the Dart side is pinned to the method name and a
//   plain String argument, the only shape the Swift handler accepts.
//
// Real time on purpose: the timing IS the behaviour.
// Run under TZ=JST-9 (as CI does): receipts carry epoch ms and timestamps.
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

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _iosChannel = MethodChannel('sis/notifications');

/// The exact key the Kotlin receiver writes, as the Dart side sees the
/// FlutterSharedPreferences file: the plugin's "flutter." prefix included.
String _arrivalKey(String id) => 'flutter.sis.push_arrival.$id';

const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';
const _title = 'Zelda Secretname';
const _body = 'the confidential body text';
const _chat = 'c-private-chat';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  late Directory support;
  late Directory cache;
  Object? showThrows;
  Object? pathThrows;

  void newIsolate() => SharedPreferences.resetStatic();

  Future<Object?> plugin(MethodCall call) async {
    if (call.method == 'show' && showThrows != null) {
      shade.calls.add(call.method);
      throw showThrows!;
    }
    return shade.handle(call);
  }

  Future<Object?> paths(MethodCall call) async {
    if (pathThrows != null) throw pathThrows!;
    return switch (call.method) {
      'getApplicationSupportDirectory' => support.path,
      'getApplicationCacheDirectory' => cache.path,
      _ => throw MissingPluginException(call.method),
    };
  }

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    showThrows = null;
    pathThrows = null;
    support = await Directory.systemTemp.createTemp('sis-support-');
    cache = await Directory.systemTemp.createTemp('sis-cache-');
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
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
    messenger.setMockMethodCallHandler(_iosChannel, null);
    await support.delete(recursive: true);
    await cache.delete(recursive: true);
  });

  var pushes = 0;

  /// A push drawn by Android's native receiver (the only drawer since
  /// Update 1).
  bool push(String chat, String title, String body) =>
      NativeReceiver(shade, disk).receive({
        'conversation_id': chat,
        'title': title,
        'body': body,
        'message_id':
            '00000000-0000-4000-8000-${(++pushes).toString().padLeft(12, '0')}',
      });

  group('PushReceiptLog', () {
    Future<List<Map<String, Object?>>> receipts() async {
      newIsolate();
      return PushReceiptLog.pending();
    }

    setUp(() => PushReceiptLog.clear());

    test('a note is stored as the receipt\'s text', () async {
      await PushReceiptLog.add(
        'received',
        messageId: _msg,
        note: 'sent=1 dart=2 native=?',
      );

      final r = (await receipts()).single;
      expect(r['error'], 'sent=1 dart=2 native=?');
      expect(r['message_id'], _msg);
    });

    test('no note and an error: the error\'s type only, as before', () async {
      await PushReceiptLog.add('error', error: StateError(_body));

      expect((await receipts()).single['error'], 'StateError');
    });

    group('takeArrival', () {
      test('reads what the native receiver wrote, as native=ms '
          'prio=delivered/original, and removes it', () async {
        disk.values[_arrivalKey(_msg)] = '1700000000123,high,normal';
        newIsolate();

        expect(
          await PushReceiptLog.takeArrival(_msg),
          'native=1700000000123 prio=high/normal',
        );
        expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
        newIsolate();
        expect(await PushReceiptLog.takeArrival(_msg), isNull);
      });

      test('a value written natively under a live isolate\'s cached copy is '
          'still read (FCM keeps its background isolate alive)', () async {
        await PushReceiptLog.takeArrival('warm-up');
        await SharedPreferences.getInstance();
        disk.values[_arrivalKey(_msg)] = '1700000000123,high,high';

        expect(
          await PushReceiptLog.takeArrival(_msg),
          'native=1700000000123 prio=high/high',
        );
      });

      test('a note the receiver drew (",n") reads as fast=native', () async {
        disk.values[_arrivalKey(_msg)] = '1700000000123,normal,normal,n';
        newIsolate();

        final got = await PushReceiptLog.takeArrival(_msg);
        expect(got, contains('native=1700000000123'));
        expect(got, contains('prio=normal/normal'));
        expect(got, contains('fast=native'));
        expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
      });

      test('a note still queued (",q") reads exactly as a drawn one', () async {
        disk.values[_arrivalKey(_msg)] = '1700000000123,normal,normal,n';
        newIsolate();
        final drawn = await PushReceiptLog.takeArrival(_msg);
        disk.values[_arrivalKey(_msg)] = '1700000000123,normal,normal,q';
        newIsolate();

        expect(await PushReceiptLog.takeArrival(_msg), drawn);
        expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
      });

      test(
        'a note settled without a suffix (not drawn) has no fast=',
        () async {
          disk.values[_arrivalKey(_msg)] = '1700000000123,high,high';
          newIsolate();

          expect(
            await PushReceiptLog.takeArrival(_msg),
            isNot(contains('fast=')),
          );
        },
      );

      test('another message\'s note is left alone', () async {
        disk.values[_arrivalKey('other')] = '1,high,high';
        newIsolate();

        expect(await PushReceiptLog.takeArrival(_msg), isNull);
        expect(disk.values.containsKey(_arrivalKey('other')), isTrue);
      });

      test('null id: null', () async {
        expect(await PushReceiptLog.takeArrival(null), isNull);
      });

      for (final bad in <Object>[
        'garbage',
        'abc,high,high',
        '1700000000123,high',
        '',
        42,
      ]) {
        test('a malformed value ($bad): null, no throw', () async {
          disk.values[_arrivalKey(_msg)] = bad;
          newIsolate();

          expect(await PushReceiptLog.takeArrival(_msg), isNull);
        });
      }

      test('a preferences file that cannot be read: null, no throw', () async {
        messenger.setMockMethodCallHandler(_prefsChannel, (call) async {
          throw PlatformException(code: 'io', message: 'disk gone');
        });
        newIsolate();

        expect(await PushReceiptLog.takeArrival(_msg), isNull);
      });
    });
  });

  group('onBackgroundPush: the received receipt carries the timings', () {
    RemoteMessage message({DateTime? sent, bool fields = true}) =>
        RemoteMessage(
          sentTime: sent,
          data: {
            'conversation_id': _chat,
            if (fields) 'title': _title,
            'body': _body,
            'message_id': _msg,
            'user_id': 'member-a',
          },
        );

    Future<List<Map<String, Object?>>> run(RemoteMessage m) async {
      newIsolate();
      await PushReceiptLog.clear();
      newIsolate();
      await onBackgroundPush(m);
      newIsolate();
      return PushReceiptLog.pending();
    }

    final shape = RegExp(r'^sent=(\d+|\?) dart=(\d+) native=(\d+|\?)');

    void expectSafe(Map<String, Object?> r) {
      final text = jsonEncode(r);
      for (final s in [_title, 'Zelda', _body, 'confidential', _chat]) {
        expect(text, isNot(contains(s)), reason: text);
      }
      expect((r['error']! as String).length, lessThanOrEqualTo(300));
    }

    test('sent, dart and native times, and the priorities; the arrival '
        'note is taken', () async {
      final sent = DateTime.now().subtract(const Duration(seconds: 3));
      disk.values[_arrivalKey(_msg)] = '1700000000123,high,normal,n';
      final before = DateTime.now().millisecondsSinceEpoch;

      final all = await run(message(sent: sent));
      final after = DateTime.now().millisecondsSinceEpoch;

      expect([for (final r in all) r['stage']], ['received', 'shown']);
      final note = all.first['error']! as String;
      final m = shape.firstMatch(note);
      expect(m, isNotNull, reason: note);
      expect(m!.group(1), '${sent.millisecondsSinceEpoch}');
      final dart = int.parse(m.group(2)!);
      expect(dart, inInclusiveRange(before, after));
      expect(m.group(3), '1700000000123');
      expect(note, contains('prio=high/normal'));
      expectSafe(all.first);
      expect(all.last['error'], isNull, reason: 'terminal unchanged');
      expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
    });

    test('no sent time and no native note: sent=? and native=?', () async {
      final all = await run(message());

      final note = all.first['error']! as String;
      final m = shape.firstMatch(note);
      expect(m, isNotNull, reason: note);
      expect(m!.group(1), '?');
      expect(m.group(3), '?');
      expectSafe(all.first);
    });

    test('a dropped push still gets its timings on received', () async {
      final all = await run(message(fields: false));

      expect(
        [for (final r in all) r['stage']],
        ['received', 'dropped:missing_fields'],
      );
      expect(shape.hasMatch(all.first['error']! as String), isTrue);
      expectSafe(all.first);
    });

    test(
      'a malformed native note: native=?, not counted as drawn, no throw',
      () async {
        disk.values[_arrivalKey(_msg)] = 'not,a,number';

        final all = await run(message());

        expect(
          [for (final r in all) r['stage']],
          ['received', 'dropped:not_drawn'],
        );
        final note = all.first['error']! as String;
        expect(shape.firstMatch(note)?.group(3), '?', reason: note);
      },
    );
  });

  group('clear() and the iPhone\'s delivered pushes', () {
    late List<MethodCall> ios;
    Object? iosThrows;

    setUp(() {
      ios = [];
      iosThrows = null;
      messenger.setMockMethodCallHandler(_iosChannel, (call) async {
        ios.add(call);
        if (iosThrows != null) throw iosThrows!;
        return null;
      });
    });

    Future<void> onIphone() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      await LocalPushDisplay.init();
    }

    test('on iOS: clearThread with the conversation id as a plain '
        'String', () async {
      await onIphone();

      await LocalPushDisplay.clear(_chat);

      expect(ios, hasLength(1));
      expect(ios.single.method, 'clearThread');
      expect(ios.single.arguments, isA<String>());
      expect(ios.single.arguments, _chat);
    });

    test('on iOS: a PlatformException is swallowed', () async {
      await onIphone();
      iosThrows = PlatformException(code: 'x');

      await expectLater(LocalPushDisplay.clear(_chat), completes);
    });

    test('on iOS: no native handler (MissingPluginException) is '
        'swallowed', () async {
      await onIphone();
      messenger.setMockMethodCallHandler(_iosChannel, null);

      await expectLater(LocalPushDisplay.clear(_chat), completes);
    });

    test('on Android: no clearThread, and the chat is still cleared', () async {
      expect(push('c1', 'Ava', 'hi'), isTrue);

      await LocalPushDisplay.clear('c1');

      expect(ios, isEmpty);
      expect(shade.childChats, isNot(contains('c1')));
    });
  });
}
