// The notification explainer, from its contract: Android's permission
// prompt is asked for once, only behind SIS's own explainer screen, which
// appears once between onboarding and Home -- and not at all when the
// platform already has an answer granting notifications. Written from
// lib/features/notifications/domain/push.dart and the provider contracts in
// push_controller.dart, never from the screen or the gate.
//
// Mounted as main.dart mounts it: SisApp behind the session gate, fakes only
// at the repository boundary, and the real SharedPrefsNotificationExplainerStore
// over Android's preferences file (DiskPrefs) -- so "once" is proven across a
// restart the way a phone restarts: a new process reading the same file.
// The last group swaps PushSourceFake for the real FirebasePushSource over
// Firebase Messaging's platform side, so the status mapping and the one
// prompt are proven against the platform, not a fake of our own interface.
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/shared_prefs_notification_explainer_store.dart';
import 'package:sis/features/notifications/domain/push.dart';
import 'package:sis/features/notifications/presentation/notification_explainer_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/onboarding_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/push_platform.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const me = Member(userId: 'u1', displayName: 'Maya');

const onboarded = OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
);

const newcomer = OwnProfile(
  userId: 'u1',
  displayName: 'Maya Google',
  tag: 'maya_google',
  onboardingDone: false,
);

/// The flag as Android's preferences file holds it (the legacy plugin
/// prefixes every key with "flutter.").
const shownKey = 'flutter.notification_explainer_shown';

final continueButton = find.byKey(
  const ValueKey('notification-explainer-continue'),
);
final explainer = find.byType(NotificationExplainerScreen);
final home = find.byType(HomeScreen);

Widget app({
  required PushSource push,
  NotificationExplainerStore store =
      const SharedPrefsNotificationExplainerStore(),
  OwnProfile profile = onboarded,
  bool signedIn = true,
}) => ProviderScope(
  overrides: [
    runtimeConfigProvider.overrideWithValue(config),
    authRepositoryProvider.overrideWithValue(
      FakeAuth(session: signedIn, member: me),
    ),
    updateRepositoryProvider.overrideWithValue(FakeUpdate()),
    chatRepositoryProvider.overrideWithValue(FakeChat()),
    presenceRepositoryProvider.overrideWithValue(PresenceFake()),
    profileRepositoryProvider.overrideWithValue(ProfileFake(profile: profile)),
    pushSourceProvider.overrideWithValue(push),
    pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    notificationExplainerStoreProvider.overrideWithValue(store),
  ],
  child: const SisApp(),
);

/// Pumps without settling: a SIS wait pulses, so settling while one is on
/// screen would never finish.
Future<void> frames(WidgetTester t, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
  late DiskPrefs disk;

  /// A new process on the same phone: nothing of the preferences file is
  /// cached in memory, the file itself is unchanged.
  void restart() => SharedPreferences.resetStatic();

  setUp(() {
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(prefsChannel, disk.handle);
    restart();
  });

  tearDown(() => messenger.setMockMethodCallHandler(prefsChannel, null));

  group('whether the explainer shows, by the platform\'s answer', () {
    for (final status in [
      PushPermissionStatus.notDetermined,
      PushPermissionStatus.denied,
    ]) {
      testWidgets('$status, never shown: the explainer, and no prompt yet', (
        t,
      ) async {
        final push = PushSourceFake(status: status);
        await t.pumpWidget(app(push: push));
        await frames(t);

        expect(continueButton, findsOneWidget);
        expect(home, findsNothing, reason: 'the explainer comes before Home');
        expect(
          push.permissionRequests,
          0,
          reason: 'Android\'s prompt only ever follows "Continue"',
        );
      });
    }

    for (final status in [
      PushPermissionStatus.authorized,
      PushPermissionStatus.provisional,
    ]) {
      testWidgets('$status: straight to Home, remembered, never a prompt', (
        t,
      ) async {
        final push = PushSourceFake(status: status);
        await t.pumpWidget(app(push: push));
        await frames(t);

        expect(home, findsOneWidget);
        expect(explainer, findsNothing);
        expect(push.permissionRequests, 0);
        expect(
          disk.values[shownKey],
          isTrue,
          reason:
              'nothing is left to explain; marking it shown keeps a later '
              'revocation from bringing the screen back',
        );
      });
    }

    testWidgets('already shown: straight to Home even though not granted', (
      t,
    ) async {
      disk.values[shownKey] = true;
      final push = PushSourceFake(status: PushPermissionStatus.denied);
      await t.pumpWidget(app(push: push));
      await frames(t);

      expect(home, findsOneWidget);
      expect(explainer, findsNothing);
      expect(push.permissionRequests, 0, reason: 'asked once, never again');
    });
  });

  group('"Continue"', () {
    for (final granted in [true, false]) {
      testWidgets('marks it shown, then asks exactly once, then Home '
          '(${granted ? 'allowed' : 'refused'})', (t) async {
        final push = PushSourceFake(
          status: PushPermissionStatus.notDetermined,
          permissionGranted: granted,
        )..holdPermission();
        await t.pumpWidget(app(push: push));
        await frames(t);

        await t.tap(continueButton);
        await frames(t, 5);

        expect(push.permissionRequests, 1);
        expect(
          disk.values[shownKey],
          isTrue,
          reason:
              'shown is recorded before the prompt: a prompt the app is '
              'killed during must not be followed by the screen again',
        );

        push.releasePermission();
        await frames(t);

        expect(home, findsOneWidget);
        expect(explainer, findsNothing);
        expect(push.permissionRequests, 1);
      });
    }
  });

  group('once, across restarts', () {
    testWidgets('refused once: the next start goes straight to Home and '
        'never asks again', (t) async {
      final push = PushSourceFake(
        status: PushPermissionStatus.notDetermined,
        permissionGranted: false,
      );
      await t.pumpWidget(app(push: push));
      await frames(t);
      await t.tap(continueButton);
      await frames(t);
      expect(home, findsOneWidget);
      expect(push.status, PushPermissionStatus.denied);

      // The app is closed and started again on the same phone.
      await t.pumpWidget(const SizedBox());
      restart();
      await t.pumpWidget(app(push: push));
      await frames(t);

      expect(home, findsOneWidget);
      expect(
        explainer,
        findsNothing,
        reason:
            'denied would show it for a first-timer; this member already '
            'saw it, and the flag must survive the restart',
      );
      expect(push.permissionRequests, 1, reason: 'one prompt, ever');
    });

    testWidgets('granted by the platform on one start, revoked later: '
        'still never shown', (t) async {
      final push = PushSourceFake(status: PushPermissionStatus.authorized);
      await t.pumpWidget(app(push: push));
      await frames(t);
      expect(home, findsOneWidget);

      await t.pumpWidget(const SizedBox());
      restart();
      push.status = PushPermissionStatus.denied;
      await t.pumpWidget(app(push: push));
      await frames(t);

      expect(explainer, findsNothing);
      expect(push.permissionRequests, 0);
    });
  });

  group('where it sits', () {
    testWidgets('after onboarding, before Home -- never before onboarding', (
      t,
    ) async {
      final push = PushSourceFake(status: PushPermissionStatus.denied);
      await t.pumpWidget(app(push: push, profile: newcomer));
      await frames(t);

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(explainer, findsNothing);

      await t.tap(find.byKey(const ValueKey('onboarding-skip')));
      await frames(t);

      expect(find.byType(OnboardingScreen), findsNothing);
      expect(continueButton, findsOneWidget);
      expect(home, findsNothing);

      await t.tap(continueButton);
      await frames(t);
      expect(home, findsOneWidget);
      expect(push.permissionRequests, 1);
    });

    testWidgets('never while signed out', (t) async {
      final push = PushSourceFake(status: PushPermissionStatus.denied);
      await t.pumpWidget(app(push: push, signedIn: false));
      await frames(t);

      expect(explainer, findsNothing);
      expect(push.permissionRequests, 0);
    });
  });

  group('fails open to Home', () {
    testWidgets('the shown flag cannot be read', (t) async {
      final push = PushSourceFake(status: PushPermissionStatus.denied);
      final store = NotificationExplainerStoreFake()
        ..readError = StateError('preferences unreadable');
      await t.pumpWidget(app(push: push, store: store));
      await frames(t);

      expect(home, findsOneWidget);
      expect(explainer, findsNothing);
      expect(push.permissionRequests, 0);
    });

    testWidgets('the platform\'s answer cannot be read', (t) async {
      final push = PushSourceFake(status: PushPermissionStatus.denied)
        ..statusError = PlatformException(code: 'unavailable');
      await t.pumpWidget(app(push: push));
      await frames(t);

      expect(home, findsOneWidget);
      expect(explainer, findsNothing);
      expect(push.permissionRequests, 0);
    });

    testWidgets('while the answer is still on its way, Home -- not the '
        'explainer, not a blank screen', (t) async {
      final push = PushSourceFake(status: PushPermissionStatus.authorized)
        ..holdStatus();
      await t.pumpWidget(app(push: push));
      await frames(t);

      expect(home, findsOneWidget);
      expect(explainer, findsNothing);

      push.releaseStatus();
      await frames(t);
      expect(home, findsOneWidget);
      expect(explainer, findsNothing);
    });
  });

  group('over Firebase Messaging\'s platform side', () {
    final device = DeviceMessaging();

    setUpAll(() async {
      setupFirebaseCoreMocks();
      await Firebase.initializeApp();
      FirebaseMessagingPlatform.instance = device;
    });

    setUp(() {
      device.prompts = 0;
      // The shade: FirebasePushSource hands each sign-in to it.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(Shade.channel, Shade().handle);
    });

    tearDown(() => messenger.setMockMethodCallHandler(Shade.channel, null));

    PushSource source() => FirebasePushSource(FirebaseMessaging.instance);

    testWidgets('already allowed on the phone: Home, and no prompt', (t) async {
      device.status = AuthorizationStatus.authorized;
      await t.pumpWidget(app(push: source()));
      await frames(t);

      expect(home, findsOneWidget);
      expect(explainer, findsNothing);
      expect(device.prompts, 0);
    });

    testWidgets('not allowed: the explainer; "Continue" is the one prompt, '
        'and a restart never shows it again', (t) async {
      device
        ..status = AuthorizationStatus.denied
        ..answer = AuthorizationStatus.denied;
      await t.pumpWidget(app(push: source()));
      await frames(t);
      expect(continueButton, findsOneWidget);
      expect(device.prompts, 0);

      await t.tap(continueButton);
      await frames(t);
      expect(device.prompts, 1);
      expect(home, findsOneWidget);

      await t.pumpWidget(const SizedBox());
      restart();
      await t.pumpWidget(app(push: source()));
      await frames(t);
      expect(explainer, findsNothing);
      expect(device.prompts, 1);
    });
  });
}
