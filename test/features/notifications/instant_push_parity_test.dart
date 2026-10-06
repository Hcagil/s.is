// Update 1: on Android the native receiver (PushArrivalReceiver.kt +
// InstantPush.kt) is the only thing that draws a chat notification; the
// deferred Dart handler records the receipt and draws nothing. Written from
// the contract, not the code.
//
// Two halves:
// - Parity, against vectors the Kotlin tests read too, so neither language
//   can drift alone:
//   - test/fixtures/instant_push_vectors.json (InstantPushTest.kt): the
//     notification id of each conversation. Dart must compute the same id,
//     or clear() leaves the native notification behind.
//   - test/fixtures/alert_channel_vectors.json (InstantPushChannelTest.kt):
//     the effective alert and the channel id for the saved settings. The
//     native draw must land on the channel Dart created before Update 1, or
//     a chat's sound changes.
// - The seam: the native receiver cannot run here; NativeReceiver
//   (test/support/push_platform.dart) leaves what it leaves -- the
//   notification under the conversation's id and the arrival note -- and the
//   real background handler runs afterwards in a fresh isolate.
//
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
const _owner = 'member-a';
const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, Object?>;

final _ids = (_fixture('instant_push_vectors.json')['ids']! as List)
    .cast<Map<String, Object?>>();
final _alerts = (_fixture('alert_channel_vectors.json')['alerts']! as List)
    .cast<Map<String, Object?>>();

/// The arrival note's key, as the Kotlin receiver writes it.
String _arrivalKey(String id) => 'flutter.sis.push_arrival.$id';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;

  void newIsolate() => SharedPreferences.resetStatic();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(Shade.channel, shade.handle);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    newIsolate();
    await LocalPushDisplay.init();
    await LocalPushDisplay.forUser(_owner);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
  });

  group('parity with InstantPush.kt (shared vectors)', () {
    test('the vectors are there', () {
      expect(_ids, isNotEmpty);
      expect(_alerts, isNotEmpty);
    });

    for (final v in _ids) {
      final chat = v['conversation_id']! as String;
      final id = v['id']! as int;
      test('clear("$chat") takes away the notification the native side '
          'drew under id $id', () async {
        // A notification for another chat stays: clear is by id.
        shade.posted[id] = {'id': id, 'payload': chat};
        shade.posted[id ^ 1] = {'id': id ^ 1, 'payload': 'someone-else'};
        disk.values['flutter.sis.push_inbox.$_owner'] = jsonEncode([
          {
            'c': chat,
            't': 'Zelda',
            'g': false,
            'l': [
              {'s': '', 'x': 'hi', 'a': 1, 'm': _msg},
            ],
            'n': 1,
            'p': 1,
          },
        ]);
        newIsolate();

        await LocalPushDisplay.clear(chat);

        expect(shade.posted.keys, isNot(contains(id)));
        expect(shade.posted.keys, contains(id ^ 1));
      });
    }

    for (final v in _alerts) {
      test('channel: ${v['name']}', () async {
        if (v['defaults'] case final String d) {
          disk.values['flutter.sis.alert_defaults'] = d;
        }
        if (v['chats'] case final String c) {
          disk.values['flutter.sis.alert_chats'] = c;
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
        expect(a.tone, v['tone'], reason: 'tone');
        expect(alertChannelId(a), v['channel_id']);
      });
    }
  });

  group('the deferred Dart handler after the native receiver', () {
    const chat = 'c-private-chat';

    RemoteMessage message() => const RemoteMessage(
      data: {
        'conversation_id': chat,
        'title': 'Zelda',
        'body': 'late but here',
        'message_id': _msg,
        'user_id': _owner,
      },
    );

    /// The handler as Doze finally lets it run: a fresh isolate.
    Future<List<Map<String, Object?>>> deferredHandler() async {
      newIsolate();
      await PushReceiptLog.clear();
      newIsolate();
      shade.calls.clear();
      await onBackgroundPush(message());
      newIsolate();
      return PushReceiptLog.pending();
    }

    test('drawn natively: the handler leaves it exactly as drawn -- no post, '
        'no cancel -- and the receipt is shown, fast=native', () async {
      expect(NativeReceiver(shade, disk).receive(message().data), isTrue);
      final drawn = jsonEncode(shade.posted.values.toList());

      final receipts = await deferredHandler();

      expect([for (final r in receipts) r['stage']], ['received', 'shown']);
      final note = receipts.first['error']! as String;
      expect(note, contains('fast=native'), reason: note);
      expect(shade.calls, isNot(contains('show')));
      expect(shade.calls, isNot(contains('cancel')));
      expect(shade.calls, isNot(contains('cancelAll')));
      expect(jsonEncode(shade.posted.values.toList()), drawn);
      expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
    });

    test('the receipt carries the note\'s time and priorities', () async {
      shade.posted[NativeReceiver.notificationId(chat)] = {'payload': chat};
      disk.values[_arrivalKey(_msg)] = '1700000000123,?,?,n';

      final receipts = await deferredHandler();

      final note = receipts.first['error']! as String;
      expect(note, contains('fast=native'));
      expect(note, contains('native=1700000000123'), reason: note);
      expect(note, contains('prio=?/?'), reason: note);
    });

    test(
      'still queued natively (",q"): shown, fast=native, as if drawn',
      () async {
        disk.values[_arrivalKey(_msg)] = '1700000000123,normal,normal,q';

        final receipts = await deferredHandler();

        expect([for (final r in receipts) r['stage']], ['received', 'shown']);
        expect(receipts.first['error'], contains('fast=native'));
        expect(shade.calls, isNot(contains('show')));
      },
    );

    test('settled as not drawn: dropped:not_drawn, and Dart does not draw '
        'it instead', () async {
      disk.values[_arrivalKey(_msg)] = '1700000000123,high,high';

      final receipts = await deferredHandler();

      expect(
        [for (final r in receipts) r['stage']],
        ['received', 'dropped:not_drawn'],
      );
      expect(receipts.first['error'], isNot(contains('fast=')));
      expect(shade.posted, isEmpty);
      expect(shade.calls, isNot(contains('show')));
    });

    test('no arrival note at all: dropped:not_drawn, nothing drawn', () async {
      final receipts = await deferredHandler();

      expect(
        [for (final r in receipts) r['stage']],
        ['received', 'dropped:not_drawn'],
      );
      expect(shade.posted, isEmpty);
      expect(shade.calls, isNot(contains('show')));
    });
  });
}
