// The 0.26 alert settings' data side against the device fakes in
// test/support/push_platform.dart: the on-disk preferences file shared by
// every isolate, and Android's notification channels (fixed once created).
//
// Contract under test (not the implementation):
// - SharedPrefsAlertStore keeps defaults and per-chat overrides in shared
//   preferences, reloads on every load (the background isolate draws the
//   notification and must see a save the app made after it started),
//   treats corrupt JSON as "nothing saved", keeps only non-default chats,
//   and prunes channels after every save without ever throwing.
// - LocalPushDisplay.pruneChannels deletes msg-* channels and the legacy
//   'messages' channel that no setting uses; it leaves every other channel
//   alone and never rethrows (errors go to PushReceiptLog).
// - ChannelTonePicker talks to 'sis/tone_picker'.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/channel_tone_picker.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/push_receipt_log.dart';
import 'package:sis/features/notifications/data/shared_prefs_alert_store.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';

import '../../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pickerChannel = MethodChannel('sis/tone_picker');
const _defaultsKey = 'flutter.sis.alert_defaults';
const _chatsKey = 'flutter.sis.alert_chats';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  Object? channelsThrow;
  Object? deleteThrows;

  void newIsolate() => SharedPreferences.resetStatic();

  Future<Object?> plugin(MethodCall call) async {
    if (call.method == 'getNotificationChannels' && channelsThrow != null) {
      throw channelsThrow!;
    }
    if (call.method == 'deleteNotificationChannel' && deleteThrows != null) {
      throw deleteThrows!;
    }
    return shade.handle(call);
  }

  /// Channels an older build or an earlier setting left on the phone.
  void existingChannels(Iterable<String> ids) {
    for (final id in ids) {
      shade.channels[id] = {
        'id': id,
        'name': id,
        'description': null,
        'groupId': null,
        'showBadge': true,
        'importance': 4,
        'bypassDnd': false,
        'playSound': true,
        'enableLights': false,
        'enableVibration': true,
        'vibrationPattern': null,
        'ledColor': 0,
        'audioAttributesUsage': 5,
      };
    }
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    channelsThrow = null;
    deleteThrows = null;
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    newIsolate();
    await LocalPushDisplay.init();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_pickerChannel, null);
  });

  group('SharedPrefsAlertStore', () {
    const store = SharedPrefsAlertStore();
    const custom = AlertDefaults(
      sound: false,
      tone: 'content://media/internal/audio/media/7',
      toneName: 'Chime',
      vibration: false,
    );

    test('nothing saved: the defaults and no chat overrides', () async {
      expect(await store.loadDefaults(), const AlertDefaults());
      expect(await store.loadChats(), isEmpty);
    });

    test('defaults survive a restart: a new isolate and a new store '
        'instance read them back', () async {
      await store.saveDefaults(custom);
      expect(disk.values, contains(_defaultsKey), reason: 'on disk');

      newIsolate();
      expect(await const SharedPrefsAlertStore().loadDefaults(), custom);
    });

    test('a save made by another isolate after this one loaded is seen on '
        'the next load', () async {
      // This isolate (the background one drawing pushes) reads first...
      expect(await store.loadDefaults(), const AlertDefaults());
      expect(await store.loadChats(), isEmpty);

      // ...then the app's isolate saves. Simulated as a write to the shared
      // file underneath this isolate's in-memory copy.
      final mine = Map<String, Object>.of(disk.values);
      newIsolate();
      await store.saveDefaults(custom);
      await store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));
      final theirs = Map<String, Object>.of(disk.values);
      disk.values = mine;
      newIsolate();
      await SharedPreferences.getInstance(); // the stale copy
      disk.values = theirs;

      expect(await store.loadDefaults(), custom);
      expect(await store.loadChats(), {
        'c1': const ChatAlert(sound: AlertChoice.off),
      });
    });

    test('loadChats alone reloads too: a chat saved by another isolate is '
        'seen without a loadDefaults first', () async {
      expect(await store.loadChats(), isEmpty);

      final mine = Map<String, Object>.of(disk.values);
      newIsolate();
      await store.saveChat('c1', const ChatAlert(vibration: AlertChoice.off));
      final theirs = Map<String, Object>.of(disk.values);
      disk.values = mine;
      newIsolate();
      await SharedPreferences.getInstance(); // the stale copy
      disk.values = theirs;

      expect(await store.loadChats(), {
        'c1': const ChatAlert(vibration: AlertChoice.off),
      });
    });

    test('per-chat overrides persist; setting a chat back to Default '
        'removes its entry and leaves the others', () async {
      await store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));
      await store.saveChat('c2', const ChatAlert(vibration: AlertChoice.on));

      newIsolate();
      expect(await store.loadChats(), {
        'c1': const ChatAlert(sound: AlertChoice.off),
        'c2': const ChatAlert(vibration: AlertChoice.on),
      });

      await store.saveChat('c1', const ChatAlert());
      newIsolate();
      final chats = await store.loadChats();
      expect(chats.keys, ['c2']);
      expect(jsonEncode(disk.values), isNot(contains('"c1"')));
    });

    test('a Default chat is never stored', () async {
      await store.saveChat('c9', const ChatAlert());
      newIsolate();
      expect(await store.loadChats(), isEmpty);
    });

    test('corrupt JSON reads as nothing saved, and does not throw', () async {
      disk.values[_defaultsKey] = '{not json';
      disk.values[_chatsKey] = '[[[';
      newIsolate();
      expect(await store.loadDefaults(), const AlertDefaults());
      expect(await store.loadChats(), isEmpty);
    });

    test('valid JSON of the wrong shape reads as nothing saved', () async {
      disk.values[_defaultsKey] = '[1, 2]';
      disk.values[_chatsKey] = '"a string"';
      newIsolate();
      expect(await store.loadDefaults(), const AlertDefaults());
      expect(await store.loadChats(), isEmpty);
    });

    test(
      'a corrupt stored value can be overwritten by the next save',
      () async {
        disk.values[_defaultsKey] = '{not json';
        disk.values[_chatsKey] = '[[[';
        newIsolate();
        await store.saveDefaults(custom);
        await store.saveChat('c1', const ChatAlert(sound: AlertChoice.on));
        newIsolate();
        expect(await store.loadDefaults(), custom);
        expect(await store.loadChats(), {
          'c1': const ChatAlert(sound: AlertChoice.on),
        });
      },
    );

    test('saving defaults prunes channels no setting uses', () async {
      existingChannels([
        'messages', // pre-0.26
        'msg-sys-v1',
        'msg-sys-v0',
        'msg-off-v1',
        'summary',
        'fcm_fallback_notification_channel',
      ]);

      await store.saveDefaults(const AlertDefaults(vibration: false));

      expect(shade.channels.keys.toSet(), {
        'msg-sys-v0',
        'summary',
        'fcm_fallback_notification_channel',
      });
    });

    test('saving a chat prunes too, and keeps the chat\'s channel', () async {
      existingChannels([
        'messages',
        'msg-sys-v1',
        'msg-off-v1',
        'msg-off-v0',
        'summary',
      ]);

      await store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));

      expect(shade.channels.keys.toSet(), {
        'msg-sys-v1',
        'msg-off-v1',
        'summary',
      });
    });

    test('a failing channel listing does not fail the save', () async {
      existingChannels(['messages']);
      channelsThrow = PlatformException(code: 'boom', message: 'list failed');

      await store.saveDefaults(custom);
      await store.saveChat('c1', const ChatAlert(sound: AlertChoice.on));

      newIsolate();
      expect(await store.loadDefaults(), custom);
      expect(await store.loadChats(), hasLength(1));
    });
  });

  group('LocalPushDisplay.pruneChannels', () {
    test(
      'uses the saved settings: a chat override keeps its channel',
      () async {
        const store = SharedPrefsAlertStore();
        await store.saveChat('c1', const ChatAlert(vibration: AlertChoice.off));
        existingChannels([
          'msg-sys-v1',
          'msg-sys-v0',
          'msg-off-v1',
          'messages',
        ]);

        await LocalPushDisplay.pruneChannels();

        expect(shade.channels.keys.toSet(), {'msg-sys-v1', 'msg-sys-v0'});
      },
    );

    test('never throws, and logs the error, when listing fails', () async {
      existingChannels(['messages']);
      channelsThrow = PlatformException(code: 'boom', message: 'list failed');

      await expectLater(LocalPushDisplay.pruneChannels(), completes);

      newIsolate();
      expect(
        jsonEncode(await PushReceiptLog.pending()),
        contains('pruneChannels'),
      );
    });

    // L2: the Dart action code is gone; the list it kept on disk goes too.
    const actionsKey = 'flutter.sis.push_actions';

    test('removes the stale push_actions list and nothing else', () async {
      const store = SharedPrefsAlertStore();
      await store.saveChat('c1', const ChatAlert(vibration: AlertChoice.off));
      disk.values[actionsKey] = '[{"c":"c1","t":"v1.old.sig"}]';
      disk.values['flutter.sis.push_inbox_owner'] = 'member-a';
      newIsolate();

      await LocalPushDisplay.pruneChannels();

      expect(disk.values.containsKey(actionsKey), isFalse, reason: '$disk');
      expect(disk.values['flutter.sis.push_inbox_owner'], 'member-a');
      expect(disk.values.containsKey(_chatsKey), isTrue);
    });

    test('never throws when removing the stale list fails', () async {
      disk.values[actionsKey] = '[]';
      newIsolate();
      await SharedPreferences.getInstance();
      messenger.setMockMethodCallHandler(_prefsChannel, (call) async {
        if (call.method == 'remove' || call.method.startsWith('clear')) {
          throw PlatformException(code: 'boom', message: 'remove failed');
        }
        return disk.handle(call);
      });

      await expectLater(LocalPushDisplay.pruneChannels(), completes);
    });

    test('never throws when deleting fails', () async {
      existingChannels(['messages', 'msg-off-v0']);
      deleteThrows = PlatformException(code: 'boom', message: 'delete failed');

      await expectLater(LocalPushDisplay.pruneChannels(), completes);
    });

    test(
      'on iOS there are no channels: nothing is asked of the plugin',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final before = shade.calls.length;

        await expectLater(LocalPushDisplay.pruneChannels(), completes);

        expect(
          shade.calls.sublist(before),
          isNot(contains('deleteNotificationChannel')),
        );
      },
    );
  });

  group('ChannelTonePicker', () {
    final asked = <MethodCall>[];
    void answer(Object? Function(MethodCall) reply) {
      asked.clear();
      messenger.setMockMethodCallHandler(_pickerChannel, (call) async {
        asked.add(call);
        return reply(call);
      });
    }

    test(
      'passes the current tone and returns what the member picked',
      () async {
        answer((_) => {'uri': 'content://tone/3', 'name': 'Bell'});

        final picked = await const ChannelTonePicker().pick('content://tone/1');

        expect(asked.single.method, 'pick');
        expect(asked.single.arguments, {'current': 'content://tone/1'});
        expect(picked, isNotNull);
        expect(picked!.tone, 'content://tone/3');
        expect(picked.name, 'Bell');
      },
    );

    test('the system default comes back as a null tone', () async {
      answer((_) => {'uri': null, 'name': 'Default'});

      final picked = await const ChannelTonePicker().pick(null);

      expect(asked.single.arguments, {'current': null});
      expect(picked, isNotNull, reason: 'picking the default is not cancel');
      expect(picked!.tone, isNull);
    });

    test('cancelled (null) is null', () async {
      answer((_) => null);
      expect(await const ChannelTonePicker().pick(null), isNull);
    });

    test('a platform error is null, not a throw', () async {
      answer((_) => throw PlatformException(code: 'no_activity'));
      expect(await const ChannelTonePicker().pick(null), isNull);
    });
  });
}
