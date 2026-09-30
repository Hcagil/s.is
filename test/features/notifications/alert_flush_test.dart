// The background-drawn notification honours the 0.26 alert settings,
// against the device fakes in test/support/push_platform.dart.
//
// Contract under test (not the implementation): a flush loads the saved
// defaults and per-chat overrides (as saved by SharedPrefsAlertStore, from
// any isolate) and posts each chat's alerting notification on
// alertChannelId(resolveAlert(defaults, chat)), with playSound, sound and
// enableVibration to match; the summary stays on its own fixed, silent
// 'summary' channel; on iOS presentSound follows the effective sound.
//
// Android fixes a channel's sound and vibration when it is first created,
// so the channel a post names IS what the member hears; the Shade records
// channels that way and the tests check both the post and the channel.
//
// Each test starts as a fresh isolate (resetForTest), so its first flush
// may alert (0.25.2): the one chat post it makes is the alerting one.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/shared_prefs_alert_store.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _store = SharedPrefsAlertStore();
const _tone = 'content://media/internal/audio/media/42';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;

  void newIsolate() {
    SharedPreferences.resetStatic();
    LocalPushDisplay.resetForTest();
  }

  /// LocalPushDisplay.init, tolerating the iOS failure reported by the
  /// 'init completes on iOS' test below, so the presentSound flag can still
  /// be checked on its own.
  Future<void> init() async {
    try {
      await LocalPushDisplay.init();
    } on ArgumentError {
      if (defaultTargetPlatform != TargetPlatform.iOS) rethrow;
    }
  }

  Future<void> start(TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    if (platform == TargetPlatform.iOS) {
      IOSFlutterLocalNotificationsPlugin.registerWith();
    } else {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
    }
    newIsolate();
    await init();
    await LocalPushDisplay.forUser('member-a');
  }

  setUp(() async {
    shade = Shade();
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(Shade.channel, shade.handle);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    await start(TargetPlatform.android);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
  });

  /// A push handled by a fresh background isolate, as FCM runs it.
  Future<void> backgroundPush(String chat) async {
    newIsolate();
    await init();
    expect(
      await LocalPushDisplay.show(
        conversationId: chat,
        title: 'Ava',
        body: 'hi',
      ),
      isTrue,
    );
  }

  Map<String, Object?> spec(Map<String, Object?> n) =>
      Map<String, Object?>.from(n['platformSpecifics']! as Map);

  /// The chat's post that was allowed to alert.
  Map<String, Object?> alertingPost(String chat) {
    final posts = [
      for (final s in shade.shows)
        if (s.n['payload'] == chat && !Shade.alerting(s.n).summary) s.n,
    ];
    final alerting = [
      for (final n in posts)
        if (!Shade.alerting(n).silent) n,
    ];
    expect(alerting, hasLength(1), reason: 'posts for $chat: $posts');
    return spec(alerting.single);
  }

  void expectAndroidAlert(
    String chat, {
    required String channel,
    required bool sound,
    required String? tone,
    required bool vibration,
  }) {
    final s = alertingPost(chat);
    expect(s['channelId'], channel);
    expect(s['playSound'], sound, reason: 'playSound: $s');
    expect(s['enableVibration'], vibration, reason: 'enableVibration: $s');
    expect(s['sound'], tone, reason: 'sound: $s');
    if (tone != null) {
      expect(
        s['soundSource'],
        1 /* AndroidNotificationSoundSource.uri: a uri, not a raw resource */,
      );
    }
    // What Android will actually do: the channel's fixed settings.
    final c = shade.channels[channel];
    expect(c, isNotNull, reason: 'channel $channel was never created');
    expect(c!['playSound'], sound, reason: 'channel: $c');
    expect(c['enableVibration'], vibration, reason: 'channel: $c');
    expect(c['sound'], tone, reason: 'channel: $c');
  }

  test('nothing saved: system sound with vibration, on msg-sys-v1', () async {
    await backgroundPush('c1');

    expectAndroidAlert(
      'c1',
      channel: 'msg-sys-v1',
      sound: true,
      tone: null,
      vibration: true,
    );
  });

  test('a custom default tone: its own channel, playing that uri', () async {
    await _store.saveDefaults(const AlertDefaults().withTone(_tone, 'Chime'));

    await backgroundPush('c1');

    expectAndroidAlert(
      'c1',
      channel: alertChannelId(
        const EffectiveAlert(sound: true, tone: _tone, vibration: true),
      ),
      sound: true,
      tone: _tone,
      vibration: true,
    );
  });

  test(
    'a chat set to sound Off makes no sound, even with a default tone',
    () async {
      await _store.saveDefaults(const AlertDefaults().withTone(_tone, 'Chime'));
      await _store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));

      await backgroundPush('c1');

      expectAndroidAlert(
        'c1',
        channel: 'msg-off-v1',
        sound: false,
        tone: null,
        vibration: true,
      );
    },
  );

  test('a chat set to vibration Off does not vibrate', () async {
    await _store.saveChat('c1', const ChatAlert(vibration: AlertChoice.off));

    await backgroundPush('c1');

    expectAndroidAlert(
      'c1',
      channel: 'msg-sys-v0',
      sound: true,
      tone: null,
      vibration: false,
    );
  });

  test(
    'global sound off: a Default chat follows it, an On chat sounds',
    () async {
      await _store.saveDefaults(const AlertDefaults(sound: false));
      await _store.saveChat('c2', const ChatAlert(sound: AlertChoice.on));

      await backgroundPush('c1');
      expectAndroidAlert(
        'c1',
        channel: 'msg-off-v1',
        sound: false,
        tone: null,
        vibration: true,
      );

      await backgroundPush('c2');
      expectAndroidAlert(
        'c2',
        channel: 'msg-sys-v1',
        sound: true,
        tone: null,
        vibration: true,
      );
      expect(shade.channels.keys, isNot(contains('messages')));
    },
  );

  test('a setting saved by the app after the background isolate started is '
      'used for the next push', () async {
    // The background isolate reads the preferences first...
    newIsolate();
    await LocalPushDisplay.init();
    await SharedPreferences.getInstance();
    final stale = Map<String, Object>.of(disk.values);

    // ...then the app's isolate saves underneath its copy.
    SharedPreferences.resetStatic();
    await _store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));
    final saved = Map<String, Object>.of(disk.values);
    disk.values = stale;
    SharedPreferences.resetStatic();
    await SharedPreferences.getInstance();
    disk.values = saved;

    expect(
      await LocalPushDisplay.show(
        conversationId: 'c1',
        title: 'Ava',
        body: 'hi',
      ),
      isTrue,
    );
    expect(alertingPost('c1')['channelId'], 'msg-off-v1');
    expect(alertingPost('c1')['playSound'], isFalse);
  });

  test(
    'the summary is on its own silent channel, whatever the settings',
    () async {
      await _store.saveDefaults(const AlertDefaults().withTone(_tone, 'Chime'));

      await backgroundPush('c1');

      final summaries = [
        for (final s in shade.shows)
          if (Shade.alerting(s.n).summary) spec(s.n),
      ];
      expect(summaries, isNotEmpty);
      for (final s in summaries) {
        expect(s['channelId'], 'summary');
        expect(s['silent'], isTrue);
      }
      expect(shade.channels['summary']?['playSound'], isFalse);
    },
  );

  group('iOS', () {
    setUp(() => start(TargetPlatform.iOS));

    // main.dart calls LocalPushDisplay.init() on every platform, and the
    // background handler calls it before show(). On iOS the plugin refuses
    // an initialize without Darwin settings.
    test('init completes on iOS', () async {
      await expectLater(LocalPushDisplay.init(), completes);
    });

    Map<String, Object?> iosPost(String chat) =>
        spec(shade.shows.lastWhere((s) => s.n['payload'] == chat).n);

    test('presentSound follows the chat\'s effective sound', () async {
      await _store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));

      await backgroundPush('c1');
      expect(iosPost('c1')['presentSound'], isFalse);

      await backgroundPush('c2');
      expect(iosPost('c2')['presentSound'], isTrue);
    });

    test('a sound-off chat makes no sound on iOS, summary included', () async {
      await _store.saveChat('c1', const ChatAlert(sound: AlertChoice.off));
      final mark = shade.shows.length;

      await backgroundPush('c1');

      final posts = [for (final s in shade.shows.sublist(mark)) s.n];
      expect(posts, isNotEmpty);
      for (final n in posts) {
        // No iOS details means the plugin's defaults, which present sound.
        final ios = (n['platformSpecifics'] as Map?) ?? const {};
        expect(ios['presentSound'], isFalse, reason: 'this post may sound: $n');
      }
    });
  });
}
