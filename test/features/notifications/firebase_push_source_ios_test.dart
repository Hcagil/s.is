// FirebasePushSource on an iPhone, over a stand-in for Firebase Messaging's
// platform side that behaves like iOS does, inconvenient parts included:
//
// - The APNs token is not there at launch. It arrives some time after the app
//   registers for remote notifications -- or never (simulator, no network,
//   no aps-environment entitlement).
// - Until it has arrived, getToken() THROWS (`apns-token-not-set`), exactly
//   as the iOS SDK does. A source that asks for the FCM token first gets an
//   exception, not a token.
// - getAPNSToken() is iOS-only: on Android the plugin does not answer it.
//
// Android must be untouched: no presentation options, no APNs wait.
//
// The last group mounts the real source under the real push controller: when
// APNs never arrives the phone registers nothing, and the token that comes
// later through onTokenRefresh is what gets registered.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';

import '../../support/fakes.dart';

/// Firebase Messaging's platform side on a phone.
class PhoneMessaging extends FirebaseMessagingPlatform {
  PhoneMessaging() : super();

  /// Polls of getAPNSToken() before APNs has delivered a token; null = it
  /// never does.
  int? apnsAfterPolls = 0;
  bool apnsThrows = false;
  bool getTokenThrows = false;
  String fcmToken = 'fcm-ios-token-1';

  int apnsPolls = 0;
  int getTokenCalls = 0;

  /// getToken() calls that came before APNs had a token.
  int getTokenTooEarly = 0;
  final presentation = <({bool alert, bool badge, bool sound})>[];
  var refreshes = StreamController<String>.broadcast();

  void reset() {
    apnsAfterPolls = 0;
    apnsThrows = getTokenThrows = false;
    apnsPolls = getTokenCalls = getTokenTooEarly = 0;
    presentation.clear();
    refreshes = StreamController<String>.broadcast();
  }

  /// APNs has delivered its token once [apnsAfterPolls] polls came back
  /// empty.
  bool get _apnsReady =>
      apnsAfterPolls != null && apnsPolls >= apnsAfterPolls! && !apnsThrows;

  @override
  FirebaseMessagingPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseMessagingPlatform setInitialValues({bool? isAutoInitEnabled}) => this;

  @override
  bool get isAutoInitEnabled => true;

  @override
  Future<RemoteMessage?> getInitialMessage() async => null;

  @override
  void registerBackgroundMessageHandler(BackgroundMessageHandler handler) {}

  @override
  Future<String?> getAPNSToken() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnimplementedError('getAPNSToken is iOS-only');
    }
    apnsPolls++;
    if (apnsThrows) {
      throw FirebaseException(plugin: 'firebase_messaging', code: 'unknown');
    }
    final after = apnsAfterPolls;
    if (after == null || apnsPolls <= after) return null;
    return 'apns-hex-token';
  }

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    getTokenCalls++;
    if (defaultTargetPlatform == TargetPlatform.iOS && !_apnsReady) {
      getTokenTooEarly++;
      throw FirebaseException(
        plugin: 'firebase_messaging',
        code: 'apns-token-not-set',
        message: 'APNS token has not been set yet.',
      );
    }
    if (getTokenThrows) {
      throw FirebaseException(plugin: 'firebase_messaging', code: 'unknown');
    }
    return fcmToken;
  }

  @override
  Stream<String> get onTokenRefresh => refreshes.stream;

  @override
  Future<void> setForegroundNotificationPresentationOptions({
    required bool alert,
    required bool badge,
    required bool sound,
  }) async {
    presentation.add((alert: alert, badge: badge, sound: sound));
  }

  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      const NotificationSettings(
        alert: AppleNotificationSetting.enabled,
        announcement: AppleNotificationSetting.notSupported,
        authorizationStatus: AuthorizationStatus.authorized,
        badge: AppleNotificationSetting.enabled,
        carPlay: AppleNotificationSetting.notSupported,
        lockScreen: AppleNotificationSetting.enabled,
        notificationCenter: AppleNotificationSetting.enabled,
        showPreviews: AppleShowPreviewSetting.always,
        timeSensitive: AppleNotificationSetting.notSupported,
        criticalAlert: AppleNotificationSetting.notSupported,
        sound: AppleNotificationSetting.enabled,
        providesAppNotificationSettings: AppleNotificationSetting.notSupported,
      );
}

/// Awaits [f] while advancing the fake clock in [step]s, up to [limit].
/// Returns how much fake time passed, or null if [f] never completed.
Future<Duration?> within<T>(
  WidgetTester t,
  Future<T> f,
  Duration limit, {
  Duration step = const Duration(milliseconds: 100),
  void Function(T value)? then,
}) async {
  var done = false;
  f.then((v) {
    done = true;
    then?.call(v);
  }).ignore();
  var passed = Duration.zero;
  await t.pump(Duration.zero);
  while (!done && passed < limit) {
    await t.pump(step);
    passed += step;
  }
  for (var i = 0; i < 5; i++) {
    await t.pump(Duration.zero);
  }
  return done ? passed : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final phone = PhoneMessaging();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    FirebaseMessagingPlatform.instance = phone;
  });

  setUp(phone.reset);
  // Each test runs as one platform through a TargetPlatformVariant, which
  // sets and restores defaultTargetPlatform for it.
  FirebasePushSource make() => FirebasePushSource(FirebaseMessaging.instance);
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  group('foreground presentation', () {
    testWidgets('iOS: the system alert, badge and sound are all turned off '
        'while the app is open', (t) async {
      make();
      await t.pump();
      expect(phone.presentation, [(alert: false, badge: false, sound: false)]);
    }, variant: ios);

    testWidgets('Android: never asked', (t) async {
      make();
      await t.pump();
      expect(phone.presentation, isEmpty);
    }, variant: android);
  });

  group('token()', () {
    testWidgets('iOS: waits for APNs, then asks for the FCM token once', (
      t,
    ) async {
      phone.apnsAfterPolls = 3;
      final source = make();
      String? got;
      final took = await within(
        t,
        source.token(),
        const Duration(seconds: 12),
        then: (v) => got = v,
      );
      expect(took, isNotNull, reason: 'token() never completed');
      expect(got, 'fcm-ios-token-1');
      expect(
        phone.getTokenTooEarly,
        0,
        reason: 'the FCM token was asked for before APNs had one',
      );
      expect(phone.getTokenCalls, 1);
      expect(phone.apnsPolls, greaterThanOrEqualTo(4));
    }, variant: ios);

    testWidgets('iOS: APNs already there -- no wait at all', (t) async {
      final source = make();
      String? got;
      final took = await within(
        t,
        source.token(),
        const Duration(seconds: 12),
        then: (v) => got = v,
      );
      expect(got, 'fcm-ios-token-1');
      expect(took, lessThan(const Duration(milliseconds: 500)));
    }, variant: ios);

    testWidgets('iOS: APNs never arrives -- gives up after about ten '
        'seconds (20 polls, 500 ms apart) with null, and never throws', (
      t,
    ) async {
      phone.apnsAfterPolls = null;
      final source = make();
      String? got = 'unset';
      final took = await within(
        t,
        source.token(),
        const Duration(seconds: 30),
        then: (v) => got = v,
      );
      expect(took, isNotNull, reason: 'token() waited forever');
      expect(got, isNull);
      expect(took, greaterThanOrEqualTo(const Duration(seconds: 9)));
      expect(took, lessThanOrEqualTo(const Duration(seconds: 11)));
      expect(phone.apnsPolls, inInclusiveRange(19, 21));
    }, variant: ios);

    testWidgets('iOS: APNs refusing (a throw) is null, not an exception', (
      t,
    ) async {
      phone.apnsThrows = true;
      final source = make();
      String? got = 'unset';
      final took = await within(
        t,
        source.token(),
        const Duration(seconds: 30),
        then: (v) => got = v,
      );
      expect(took, isNotNull, reason: 'token() threw or never completed');
      expect(got, isNull);
    }, variant: ios);

    testWidgets('iOS: getToken throwing after APNs arrived is null', (t) async {
      phone.getTokenThrows = true;
      final source = make();
      String? got = 'unset';
      final took = await within(
        t,
        source.token(),
        const Duration(seconds: 30),
        then: (v) => got = v,
      );
      expect(took, isNotNull, reason: 'token() threw or never completed');
      expect(got, isNull);
    }, variant: ios);

    testWidgets('Android: straight to getToken, APNs never asked', (t) async {
      final source = make();
      String? got;
      final took = await within(
        t,
        source.token(),
        const Duration(seconds: 12),
        then: (v) => got = v,
      );
      expect(got, 'fcm-ios-token-1');
      expect(took, lessThan(const Duration(milliseconds: 500)));
      expect(phone.apnsPolls, 0);
      expect(phone.getTokenCalls, 1);
    }, variant: android);
  });

  group('under the real push controller', () {
    testWidgets('iOS without APNs: nothing is registered at start; the token '
        'that arrives later by refresh is', (t) async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            (_) async => null,
          );
      phone.apnsAfterPolls = null;
      final source = make();
      final registry = PushRegistryFake();
      final c = ProviderContainer.test(
        overrides: [
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: 'https://x.supabase.co',
              supabasePublishableKey: 'k',
              googleWebClientId: 'c',
            ),
          ),
          authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
          pushSourceProvider.overrideWithValue(source),
          pushRegistryProvider.overrideWithValue(registry),
        ],
      );
      c.listen(sessionControllerProvider, (_, _) {});
      await within(
        t,
        c.read(sessionControllerProvider.future),
        const Duration(seconds: 5),
      );
      c.listen(pushRegistrationProvider, (_, _) {});
      // Past the whole APNs wait.
      for (var i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(phone.apnsPolls, greaterThan(0), reason: 'token() never ran');
      expect(registry.calls, isEmpty);
      expect(c.read(pushRegistrationProvider), isNull);

      phone.refreshes.add('fcm-ios-late');
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(registry.registered, ['fcm-ios-late']);
      expect(c.read(pushRegistrationProvider), 'fcm-ios-late');
      c.dispose();
    }, variant: ios);
  });
}
