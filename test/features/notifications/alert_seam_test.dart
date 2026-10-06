// The seam of the 0.26 alert settings, wired as main.dart wires it:
// alertStoreProvider -> const SharedPrefsAlertStore(), tonePickerProvider ->
// const ChannelTonePicker(). Nothing of the feature is faked; only the device
// is, below the method channels (test/support/push_platform.dart for the
// preferences file and the notification plugin, and the native side of
// 'sis/tone_picker' answered here as MainActivity does).
//
// One chain per criterion: a control on the settings page or profile page
// -> AlertController -> SharedPrefsAlertStore -> the preferences file ->
// the channel the native drawer posts on for those saved settings (the
// mapping is pinned to InstantPush.kt by test/fixtures/
// alert_channel_vectors.json; the drawing itself is NativeDrawTest.kt).
// Plus the failure path of every connection: the picker failing or being
// cancelled, and channel housekeeping failing under a save.
//
// No Supabase is involved, so this runs in the ordinary suite, not under
// test/integration.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/features/notifications/application/alert_controller.dart';
import 'package:sis/features/notifications/data/channel_tone_picker.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/shared_prefs_alert_store.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';
import 'package:sis/features/notifications/presentation/alert_widgets.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pickerChannel = MethodChannel('sis/tone_picker');
const _tone = 'content://media/internal/audio/media/42';

Finder byKey(String key) => find.byKey(ValueKey(key));

/// A widget test on Android; the override is undone even when it fails.
void onAndroid(String description, WidgetTesterCallback body) =>
    testWidgets(description, (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(t);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  late Object? Function(MethodCall) nativePicker;
  late int pickerCalls;
  Object? channelsThrow;

  Future<Object?> plugin(MethodCall call) async {
    if (call.method == 'getNotificationChannels' && channelsThrow != null) {
      throw channelsThrow!;
    }
    return shade.handle(call);
  }

  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    channelsThrow = null;
    pickerCalls = 0;
    nativePicker = (_) => null;
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    messenger.setMockMethodCallHandler(_pickerChannel, (call) async {
      pickerCalls++;
      return nativePicker(call);
    });
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_pickerChannel, null);
  });

  /// The app's settings page, freshly started (a new isolate).
  Future<void> openApp(WidgetTester t) async {
    SharedPreferences.resetStatic();
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      ProviderScope(
        // As main.dart mounts it.
        overrides: [
          alertStoreProvider.overrideWithValue(const SharedPrefsAlertStore()),
          tonePickerProvider.overrideWithValue(const ChannelTonePicker()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AlertDefaultsSection(),
                ChatAlertTiles(conversationId: 'c1'),
              ],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(byKey('alert-sound'), findsOneWidget, reason: 'settings loaded');
  }

  /// Lets a save finish: its platform calls, and any timer on the way
  /// (pumpAndSettle alone does not advance time when no frame is pending).
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 500));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await t.pumpAndSettle();
  }

  bool switchOn(WidgetTester t, String key) =>
      t.widget<SisSwitchTile>(byKey(key)).value;

  /// Taps [key] and lets the save it starts finish. The save goes through
  /// the real SharedPreferences and the plugin's method channels, and on
  /// failure through PushReceiptLog, some of which completes in real time.
  Future<void> tapAndSettle(WidgetTester t, String key) async {
    await t.tap(byKey(key));
    await settle(t);
  }

  Future<void> choose(WidgetTester t, String dropdownKey, String item) async {
    await tapAndSettle(t, dropdownKey);
    await t.tap(find.text(item).last);
    await settle(t);
  }

  /// A push drawn in the background. Since Update 1 the native receiver
  /// draws it: it reads the saved settings straight from the preferences
  /// file and posts on the channel for them, creating it if needed. That
  /// channel id is computed here by the Dart reference, which
  /// test/fixtures/alert_channel_vectors.json holds equal to the Kotlin
  /// code (InstantPushChannelTest.kt). Returns what the post plays.
  Future<Map<String, Object?>> backgroundPush(
    WidgetTester t,
    String chat,
  ) async {
    return (await t.runAsync(() async {
      SharedPreferences.resetStatic();
      const store = SharedPrefsAlertStore();
      final a = resolveAlert(
        await store.loadDefaults(),
        (await store.loadChats())[chat] ?? const ChatAlert(),
      );
      final post = <String, Object?>{
        'channelId': alertChannelId(a),
        'playSound': a.sound,
        'sound': a.tone,
        'enableVibration': a.vibration,
      };
      await shade.handle(
        MethodCall('createNotificationChannel', {
          ...post,
          'id': post['channelId'],
          'name': 'Messages',
        }),
      );
      SharedPreferences.resetStatic();
      return post;
    }))!;
  }

  /// The settings exactly as the native receiver reads them: the raw JSON
  /// under the keys it opens ("t" is the tone).
  Map<String, Object?> saved(String key) =>
      jsonDecode(disk.values['flutter.sis.$key']! as String)
          as Map<String, Object?>;

  onAndroid('A: sound and vibration set on the settings page survive a '
      'restart', (t) async {
    await openApp(t);
    await tapAndSettle(t, 'alert-sound');
    await tapAndSettle(t, 'alert-vibration');

    await openApp(t);

    expect(switchOn(t, 'alert-sound'), isFalse);
    expect(switchOn(t, 'alert-vibration'), isFalse);
  });

  onAndroid('C: a tone picked on the settings page is what the next '
      'background notification plays, on its own channel', (t) async {
    nativePicker = (call) {
      expect(call.method, 'pick');
      return {'uri': _tone, 'name': 'Chime'};
    };
    await openApp(t);

    await tapAndSettle(t, 'alert-tone');
    expect(pickerCalls, 1);
    expect(
      find.descendant(of: byKey('alert-tone'), matching: find.text('Chime')),
      findsOneWidget,
    );

    expect(saved('alert_defaults')['t'], _tone);
    final post = await backgroundPush(t, 'c1');
    expect(post['sound'], _tone);
    expect(post['playSound'], isTrue);
    expect(post['channelId'], isNot(anyOf('msg-sys-v1', 'msg-off-v1')));
    expect(shade.channels[post['channelId']]?['sound'], _tone);

    await openApp(t);
    expect(find.text('Chime'), findsOneWidget, reason: 'kept after restart');

    // Opening the picker again offers the saved tone as the current one.
    final asked = <Object?>[];
    nativePicker = (call) {
      asked.add(call.arguments);
      return null;
    };
    await tapAndSettle(t, 'alert-tone');
    expect(asked, [
      {'current': _tone},
    ]);
  });

  onAndroid('B + C: a Default chat follows the global sound; On and Off '
      'override it', (t) async {
    await openApp(t);
    await tapAndSettle(t, 'alert-sound'); // global sound off

    var post = await backgroundPush(t, 'c1');
    expect(post['channelId'], 'msg-off-v1');
    expect(post['playSound'], isFalse);

    await choose(t, 'chat-alert-sound-choice', 'On');
    expect(saved('alert_chats')['c1'], containsPair('s', 'on'));
    post = await backgroundPush(t, 'c1');
    expect(post['channelId'], 'msg-sys-v1');
    expect(post['playSound'], isTrue);

    await choose(t, 'chat-alert-vibration-choice', 'Off');
    post = await backgroundPush(t, 'c1');
    expect(post['channelId'], 'msg-sys-v0');
    expect(post['enableVibration'], isFalse);

    await choose(t, 'chat-alert-sound-choice', 'Default');
    await tapAndSettle(t, 'alert-sound'); // global sound back on
    post = await backgroundPush(t, 'c1');
    expect(post['channelId'], 'msg-sys-v0', reason: 'Default follows global');
    expect(post['playSound'], isTrue);
  });

  onAndroid('D: a change of setting prunes the channels no longer used, '
      'including the pre-0.26 one', (t) async {
    await t.runAsync(() async {
      SharedPreferences.resetStatic();
      await LocalPushDisplay.init();
    });
    await shade.handle(
      const MethodCall('createNotificationChannel', {
        'id': 'messages',
        'name': 'Messages',
        'importance': 4,
      }),
    );
    // The native drawer's summary channel, as it leaves it.
    await shade.handle(
      const MethodCall('createNotificationChannel', {
        'id': 'summary',
        'name': 'Summary',
        'importance': 2,
      }),
    );
    await openApp(t);
    await backgroundPush(t, 'c1'); // creates msg-sys-v1
    expect(shade.channels.keys, contains('msg-sys-v1'));

    await tapAndSettle(t, 'alert-vibration');

    expect(shade.channels.keys, isNot(contains('messages')));
    expect(shade.channels.keys, isNot(contains('msg-sys-v1')));
    expect(shade.channels.keys, contains('summary'));
  });

  group('failure paths', () {
    onAndroid('the native picker fails: nothing changes and nothing is '
        'saved', (t) async {
      nativePicker = (_) => throw PlatformException(code: 'no_activity');
      await openApp(t);
      final before = Map<String, Object>.of(disk.values);

      await tapAndSettle(t, 'alert-tone');

      expect(pickerCalls, 1);
      expect(t.takeException(), isNull);
      expect(
        find.descendant(
          of: byKey('alert-tone'),
          matching: find.text('System default'),
        ),
        findsOneWidget,
      );
      expect(disk.values, before);
    });

    onAndroid('the member cancels the picker: nothing changes', (t) async {
      nativePicker = (_) => null;
      await openApp(t);
      final before = Map<String, Object>.of(disk.values);

      await tapAndSettle(t, 'alert-tone');

      expect(pickerCalls, 1);
      expect(find.text('System default'), findsOneWidget);
      expect(disk.values, before);
    });

    onAndroid('channel housekeeping fails under a save: the setting is '
        'still saved and the page carries on', (t) async {
      channelsThrow = PlatformException(code: 'boom');
      await openApp(t);

      await tapAndSettle(t, 'alert-sound');
      await choose(t, 'chat-alert-sound-choice', 'On');
      expect(t.takeException(), isNull);
      expect(switchOn(t, 'alert-sound'), isFalse);

      await openApp(t);
      expect(switchOn(t, 'alert-sound'), isFalse);
      final post = await backgroundPush(t, 'c1');
      expect(post['channelId'], 'msg-sys-v1', reason: 'chat On persisted');
    });
  });
}
