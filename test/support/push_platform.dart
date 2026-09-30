// The device under the push code: Android's notification shade, its
// SharedPreferences file, and Firebase Messaging's platform side. Written
// from what the platform does, not from what the app expects of it -- see
// test/features/notifications/local_push_display_test.dart for the reasons
// behind each inconvenient part.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The notification shade: every posted notification by id.
class Shade {
  final posted = <int, Map<String, Object?>>{};

  Map<String, Object?> _specifics(Map<String, Object?> n) =>
      Map<String, Object?>.from(
        (n['platformSpecifics'] as Map?) ?? const <String, Object?>{},
      );

  bool _isSummary(Map<String, Object?> n) =>
      _specifics(n)['setAsGroupSummary'] == true;

  List<Map<String, Object?>> get summaries => [
    for (final n in posted.values)
      if (_isSummary(n)) n,
  ];

  List<Map<String, Object?>> get children => [
    for (final n in posted.values)
      if (!_isSummary(n)) n,
  ];

  /// The chat a child opens when tapped.
  Set<Object?> get childChats => {for (final n in children) n['payload']};

  Map<String, Object?> childFor(String conversationId) =>
      children.singleWhere((n) => n['payload'] == conversationId);

  Set<Object?> get groupKeys => {
    for (final n in posted.values) _specifics(n)['groupKey'],
  };

  /// Everything a person could read on [n], expanded or not.
  static String text(Map<String, Object?> n) => jsonEncode(n);

  /// The payload of the notification whose tap started the app, if one did.
  String? launchedBy;

  /// Every call the app made into the plugin, in order.
  final calls = <String>[];

  /// Android's notification channels by id, as the app would find them.
  /// A channel is created the first time a notification names it (or when
  /// the app creates it); after that its sound and vibration are FIXED:
  /// Android ignores what a later post or create asks for. That is the
  /// inconvenient part for per-chat alert settings.
  final channels = <String, Map<String, Object?>>{};

  void _ensureChannel(Map<String, Object?> spec) {
    final id = spec['channelId'] as String?;
    if (id == null || channels.containsKey(id)) return;
    channels[id] = {
      'id': id,
      'name': spec['channelName'] ?? spec['name'] ?? id,
      'description': spec['channelDescription'] ?? spec['description'],
      'groupId': null,
      'showBadge': true,
      'importance': spec['importance'] ?? 3,
      'bypassDnd': false,
      'playSound': spec['playSound'] ?? true,
      if (spec['sound'] != null) 'sound': spec['sound'],
      if (spec['soundSource'] != null) 'soundSource': spec['soundSource'],
      'enableLights': false,
      'enableVibration': spec['enableVibration'] ?? true,
      'vibrationPattern': null,
      'ledColor': 0,
      'audioAttributesUsage': 5,
    };
  }

  /// Every notification posted, in order, with when it was posted. Android
  /// sheds posts above about 5 per second per app without an error, so the
  /// timing is part of what the app must get right.
  final shows = <({DateTime at, Map<String, Object?> n})>[];

  /// The alerting flags of [n]: whether it may sound, and how its group
  /// alerts (GroupAlertBehavior index: 0 all, 1 summary, 2 children).
  static ({bool silent, bool onlyAlertOnce, Object? groupAlert, bool summary})
  alerting(Map<String, Object?> n) {
    final s = Map<String, Object?>.from(
      (n['platformSpecifics'] as Map?) ?? const <String, Object?>{},
    );
    return (
      silent: s['silent'] == true,
      onlyAlertOnce: s['onlyAlertOnce'] == true,
      groupAlert: s['groupAlertBehavior'],
      summary: s['setAsGroupSummary'] == true,
    );
  }

  /// The most posts inside any one-second window.
  int get peakPostsPerSecond {
    var peak = 0;
    for (var i = 0; i < shows.length; i++) {
      var n = 0;
      for (var j = i; j < shows.length; j++) {
        if (shows[j].at.difference(shows[i].at) >= const Duration(seconds: 1)) {
          break;
        }
        n++;
      }
      if (n > peak) peak = n;
    }
    return peak;
  }

  static const channel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  /// The member taps the notification carrying [payload] while the app
  /// runs: Android calls into the app, as the plugin's native side does.
  static Future<void> tap(String payload) async {
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('didReceiveNotificationResponse', {
              'notificationId': 1,
              'notificationResponseType': 0,
              'payload': payload,
            }),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments;
    calls.add(call.method);
    switch (call.method) {
      case 'initialize':
        return true;
      case 'getNotificationAppLaunchDetails':
        final p = launchedBy;
        return {
          'notificationLaunchedApp': p != null,
          if (p != null)
            'notificationResponse': {
              'notificationId': 1,
              'notificationResponseType': 0,
              'payload': p,
            },
        };
      case 'show':
        final n = Map<String, Object?>.from(args as Map);
        _ensureChannel(_specifics(n));
        posted[n['id']! as int] = n;
        shows.add((at: DateTime.now(), n: n));
        return null;
      case 'cancel':
        posted.remove(args is Map ? args['id'] : args);
        return null;
      case 'cancelAll':
        posted.clear();
        return null;
      case 'createNotificationChannel':
        final spec = Map<String, Object?>.from(args as Map);
        _ensureChannel({
          ...spec,
          'channelId': spec['id'],
          'channelName': spec['name'],
        });
        return null;
      case 'getNotificationChannels':
        return [for (final c in channels.values) Map<String, Object?>.of(c)];
      case 'deleteNotificationChannel':
        channels.remove(args);
        return null;
      case 'getActiveNotifications':
        return [
          for (final n in posted.values)
            {
              'id': n['id'],
              'title': n['title'],
              'body': n['body'],
              'payload': n['payload'],
              'groupKey': _specifics(n)['groupKey'],
            },
        ];
      default:
        return null;
    }
  }
}

/// Android's SharedPreferences file: one store, shared by every isolate.
class DiskPrefs {
  Map<String, Object> values = {};

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'getAll':
        return Map<String, Object>.of(values);
      case 'getAllWithParameters':
        final prefix = args['prefix'] as String;
        final allow = (args['allowList'] as List?)?.cast<String>().toSet();
        return {
          for (final e in values.entries)
            if (e.key.startsWith(prefix) &&
                (allow == null || allow.contains(e.key)))
              e.key: e.value,
        };
      case 'remove':
        values.remove(args['key']);
        return true;
      case 'clear':
        values.clear();
        return true;
      case 'clearWithParameters':
        final prefix = args['prefix'] as String;
        values.removeWhere((k, _) => k.startsWith(prefix));
        return true;
      default:
        if (call.method.startsWith('set')) {
          values[args['key'] as String] = args['value'] as Object;
          return true;
        }
        throw MissingPluginException(call.method);
    }
  }
}

/// Firebase Messaging's platform side on one phone.
///
/// The message that cold-started the app is answered once, as Android does:
/// FCM hands the initial message over a single time. Taps on notifications
/// Android drew while the app ran in the background arrive on
/// [FirebaseMessagingPlatform.onMessageOpenedApp] -- the stream the method
/// channel feeds on a device; use [openedApp].
class DeviceMessaging extends FirebaseMessagingPlatform {
  DeviceMessaging() : super();

  /// The notification Android drew that the member tapped to start the app.
  RemoteMessage? initial;
  String? currentToken = 'fcm-token-1';
  final _refreshes = StreamController<String>.broadcast();

  /// The member taps a notification Android drew while the app was in the
  /// background.
  static void openedApp(RemoteMessage m) =>
      FirebaseMessagingPlatform.onMessageOpenedApp.add(m);

  @override
  FirebaseMessagingPlatform delegateFor({required app}) => this;

  @override
  FirebaseMessagingPlatform setInitialValues({bool? isAutoInitEnabled}) => this;

  @override
  bool get isAutoInitEnabled => true;

  @override
  Future<RemoteMessage?> getInitialMessage() async {
    final m = initial;
    initial = null;
    return m;
  }

  @override
  void registerBackgroundMessageHandler(BackgroundMessageHandler handler) {}

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async => currentToken;

  @override
  Stream<String> get onTokenRefresh => _refreshes.stream;

  /// The platform's own record of the notification permission, read by
  /// getNotificationSettings() without prompting.
  AuthorizationStatus status = AuthorizationStatus.notDetermined;

  /// What the member answers when the platform prompts; asking also updates
  /// [status], as Android's own record does.
  AuthorizationStatus answer = AuthorizationStatus.authorized;

  /// How many times the platform's permission prompt was asked for.
  int prompts = 0;

  static NotificationSettings _settings(AuthorizationStatus status) =>
      NotificationSettings(
        alert: AppleNotificationSetting.enabled,
        announcement: AppleNotificationSetting.notSupported,
        authorizationStatus: status,
        badge: AppleNotificationSetting.notSupported,
        carPlay: AppleNotificationSetting.notSupported,
        lockScreen: AppleNotificationSetting.enabled,
        notificationCenter: AppleNotificationSetting.enabled,
        showPreviews: AppleShowPreviewSetting.always,
        timeSensitive: AppleNotificationSetting.notSupported,
        criticalAlert: AppleNotificationSetting.notSupported,
        sound: AppleNotificationSetting.enabled,
        providesAppNotificationSettings: AppleNotificationSetting.notSupported,
      );

  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      _settings(status);

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    prompts++;
    status = answer;
    return _settings(status);
  }
}
