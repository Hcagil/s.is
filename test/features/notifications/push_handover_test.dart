// One phone, one member after another: what the previous member's pushes
// left behind must never reach the next one.
//
// Mounted as main.dart mounts it: the whole app behind the session gate,
// the production FirebasePushSource over Firebase Messaging, LocalPushDisplay
// initialised with FirebasePushSource.tapped, and pushes shown by the
// production background handler (onBackgroundPush). Only the device is a
// fake (test/support/push_platform.dart): the notification shade, the
// SharedPreferences file and Firebase's platform side -- and, at the
// repository boundary, auth, chat, profile and presence.
//
// Every session end is its own path through the app, and each must hand
// over cleanly: Settings > Sign out; the server ending the session; a phone
// that was replaced starting on the Denied screen and signing out there; and
// lines an earlier 0.12 build stored for everyone in one inbox.
//
// Also here, over the same device: taps on notifications Android drew itself
// (a push sent to a device still registered as an older build), and a push
// Android already drew is not drawn a second time.
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/push_platform.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const ava = Member(userId: 'member-ava', displayName: 'Ava');
const bea = Member(userId: 'member-bea', displayName: 'Bea');

OwnProfile profileOf(Member m) => OwnProfile(
  userId: m.userId,
  displayName: m.displayName,
  tag: m.displayName.toLowerCase(),
  onboardingDone: true,
);

/// What Ava's pushes said. None of it may reach Bea.
const avaSecrets = ['Ava secret one', 'Ava secret two', 'Zed', 'Yan'];

/// Exactly what the 0.12-pre LocalPushDisplay (24d7ac6) stored for two
/// pushes, captured from that build over these fakes: one inbox, no owner.
Map<String, Object> legacyInbox() => {
  'flutter.sis.push_inbox':
      '[{"c":"c-old-1","t":"Olga","l":["legacy secret one"],"n":1},'
      '{"c":"c-old-2","t":"Omar","l":["legacy secret two"],"n":1}]',
};
const legacySecrets = ['legacy secret one', 'legacy secret two', 'Olga'];

/// A data-only push, as notify-on-message sends it to this build.
RemoteMessage dataPush(String chat, String title, String body) => RemoteMessage(
  data: {'conversation_id': chat, 'title': title, 'body': body},
);

/// A push with a notification block, as sent to a device still registered
/// as an older build: Android draws it itself.
RemoteMessage drawnPush(String chat, String title, String body) =>
    RemoteMessage(
      notification: RemoteNotification(title: title, body: body),
      data: {'conversation_id': chat, 'title': title, 'body': body},
    );

/// Every test runs on Android, the only platform SIS ships on.
void _android(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final device = DeviceMessaging();
  late FirebasePushSource source;
  late Shade shade;
  late DiskPrefs disk;

  /// A fresh isolate: no in-memory copy of the preferences yet.
  void newIsolate() => SharedPreferences.resetStatic();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    FirebaseMessagingPlatform.instance = device;
    // main.dart makes exactly one, for the life of the process.
    source = FirebasePushSource(FirebaseMessaging.instance);
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    device.initial = null;
    messenger.setMockMethodCallHandler(Shade.channel, shade.handle);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      disk.handle,
    );
    newIsolate();
    await LocalPushDisplay.init(onTap: FirebasePushSource.tapped);
    // The test bodies run as Android through [android].
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      null,
    );
  });

  /// A push arriving while the app is in the background or closed: the
  /// production background handler, in its own isolate.
  Future<void> background(WidgetTester t, RemoteMessage m) async {
    newIsolate();
    await t.runAsync(() => onBackgroundPush(m));
  }

  Future<void> avaPushes(WidgetTester t) async {
    await background(t, dataPush('c-zed', 'Zed', 'Ava secret one'));
    await background(t, dataPush('c-yan', 'Yan', 'Ava secret two'));
    expect(shade.childChats, {'c-zed', 'c-yan'}, reason: 'precondition');
  }

  /// Starts the app as main.dart does, on [auth]'s session.
  Future<void> launch(WidgetTester t, FakeAuth auth, ProfileFake p) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(auth),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(FakeChat()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          profileRepositoryProvider.overrideWithValue(p),
          attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
          pushSourceProvider.overrideWithValue(source),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        ],
        child: const SisApp(),
      ),
    );
    await t.pumpAndSettle();
  }

  /// The app process ends (swiped away, or the phone restarts).
  Future<void> kill(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    newIsolate();
  }

  void expectHome() =>
      expect(find.text('New chat'), findsOneWidget, reason: 'not home');

  /// The session has ended: before anyone else signs in, the shade is
  /// empty and nothing of Ava's is left on disk.
  void expectAvaGone() {
    expect(shade.posted, isEmpty, reason: 'still in the shade');
    final stored = jsonEncode(disk.values);
    for (final s in avaSecrets) {
      expect(stored, isNot(contains(s)), reason: 'kept on disk: $stored');
    }
  }

  /// Bea signs in with Google on the sign-in screen.
  Future<void> beaSignsIn(WidgetTester t, FakeAuth auth, ProfileFake p) async {
    expect(find.text('Continue with Google'), findsOneWidget);
    auth
      ..member = bea
      ..allowed = true;
    p.profile = profileOf(bea);
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expectHome();
  }

  /// Bea's first push shows her chat alone, and nothing of [secrets] is
  /// readable anywhere: the shade, or the stored inbox the next summary is
  /// built from.
  Future<void> expectBeaSeesOnlyHers(
    WidgetTester t,
    List<String> secrets,
  ) async {
    final stored = jsonEncode(disk.values);
    for (final s in secrets) {
      expect(stored, isNot(contains(s)), reason: 'kept on disk: $stored');
    }

    await background(t, dataPush('c-bea', 'Cal', 'first for Bea'));

    expect(shade.childChats, {'c-bea'}, reason: '${shade.posted}');
    expect(shade.summaries, hasLength(1));
    final summary = Shade.text(shade.summaries.single);
    expect(summary, contains('1 new message'));
    expect(summary, isNot(contains('chats')), reason: 'counts leaked');
    final shown = jsonEncode(shade.posted.values.toList());
    final storedAfter = jsonEncode(disk.values);
    for (final s in secrets) {
      expect(shown, isNot(contains(s)), reason: 'shown to Bea: $shown');
      expect(storedAfter, isNot(contains(s)), reason: storedAfter);
    }
  }

  group('handover to the next member', () {
    _android('Settings > Sign out', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await avaPushes(t);

      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('settings-account')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('account-sign-out')));
      await t.pumpAndSettle();
      expect(auth.signOuts, 1);

      expectAvaGone();
      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, avaSecrets);
    });

    _android('the server ends the session while the app runs (no '
        'sign-out on this phone)', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await avaPushes(t);

      auth.session = false;
      auth.changes.add(false);
      await t.pumpAndSettle();
      expect(auth.signOuts, 0);

      expectAvaGone();
      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, avaSecrets);
    });

    _android('a replaced phone starts on the Denied screen and signs out '
        'there', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await kill(t);
      await avaPushes(t); // while the app is closed

      // Ava signed in on another phone: this one's session is no longer
      // the active one.
      auth.allowed = false;
      await launch(t, auth, p);
      expect(find.textContaining('not currently approved'), findsOneWidget);
      await t.tap(find.text('Sign out'));
      await t.pumpAndSettle();
      expect(auth.signOuts, 1);

      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, avaSecrets);
    });

    _android('a replaced phone signed out on the Denied screen keeps nothing '
        'of the previous member in the shade or on disk', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await kill(t);
      await avaPushes(t);

      auth.allowed = false;
      await launch(t, auth, p);
      expect(find.textContaining('not currently approved'), findsOneWidget);
      await t.tap(find.text('Sign out'));
      await t.pumpAndSettle();
      expect(auth.signOuts, 1);
      expect(find.text('Continue with Google'), findsOneWidget);

      // Whoever signs in next is holding the phone now: Ava's previews
      // must not be one pull of the shade away.
      expectAvaGone();
    });

    _android('the session ended while the app was closed: it starts '
        'signed out', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await kill(t);
      await avaPushes(t);

      auth.session = false;
      await launch(t, auth, p);

      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, avaSecrets);
    });

    _android('a session that ended while the app was closed leaves nothing '
        'of the previous member once the app shows sign-in', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await kill(t);
      await avaPushes(t);

      auth.session = false;
      await launch(t, auth, p);
      expect(find.text('Continue with Google'), findsOneWidget);

      expectAvaGone();
    });

    _android('lines a 0.12-pre build stored for everyone do not reach the '
        'first member after the update', (t) async {
      // The old build's member lost the session without a sign-out, so its
      // one shared inbox was never cleared.
      disk.values = legacyInbox();
      newIsolate();
      final auth = FakeAuth(member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);

      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, legacySecrets);
    });

    _android('lines a 0.12-pre build stored survive neither the member '
        'who was signed in at the update nor the next one', (t) async {
      disk.values = legacyInbox();
      newIsolate();
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await avaPushes(t);

      auth.session = false;
      auth.changes.add(false);
      await t.pumpAndSettle();

      expectAvaGone();
      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, [...legacySecrets, ...avaSecrets]);
    });

    _android('the same member starting the app again keeps what arrived '
        'while it was closed', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await kill(t);
      await avaPushes(t);

      await launch(t, auth, p);
      expectHome();

      expect(shade.childChats, {'c-zed', 'c-yan'});
      await background(t, dataPush('c-xi', 'Xi', 'third'));
      expect(
        Shade.text(shade.summaries.single),
        contains('3 new messages in 3 chats'),
      );
    });
  });

  group('taps on a notification Android drew itself', () {
    /// What the app is told to open, in order: the conversation that
    /// started it, then each one tapped while it runs.
    Future<List<String>> opened(WidgetTester t) async {
      final c = ProviderContainer.test(
        overrides: [pushSourceProvider.overrideWithValue(source)],
      );
      final seen = <String>[];
      c.listen(openedFromNotificationProvider, (_, next) {
        if (next case AsyncData(:final value)) seen.add(value);
      });
      await t.pumpAndSettle();
      return seen;
    }

    _android('one that started the app opens its chat', (t) async {
      device.initial = drawnPush('c-cold', 'Zed', 'hi');

      expect(await opened(t), ['c-cold']);
    });

    _android('one tapped while the app was in the background opens its '
        'chat', (t) async {
      final seen = await opened(t);
      expect(seen, isEmpty);

      // Platform events arrive from the real event loop, where main.dart's
      // FirebasePushSource (made in setUpAll, outside the test clock) hears
      // them.
      await t.runAsync(() async {
        DeviceMessaging.openedApp(drawnPush('c-warm', 'Zed', 'hi'));
        await Future<void>.delayed(Duration.zero);
      });
      await t.pumpAndSettle();

      expect(seen, ['c-warm']);
    });

    _android('the app\'s own notifications still open their chat, started '
        'or tapped while running', (t) async {
      shade.launchedBy = 'c-own-cold';
      final seen = await opened(t);
      expect(seen, ['c-own-cold']);

      await t.runAsync(() => Shade.tap('c-own-warm'));
      await t.pumpAndSettle();

      expect(seen, ['c-own-cold', 'c-own-warm']);
    });

    _android('a start not from a notification opens nothing', (t) async {
      expect(await opened(t), isEmpty);
    });
  });

  group('a push Android already drew', () {
    _android('is not drawn a second time by the app', (t) async {
      await background(t, drawnPush('c-dup', 'Zed', 'drawn by Android'));

      expect(shade.posted, isEmpty, reason: 'a duplicate: ${shade.posted}');
    });

    _android('a data-only push is still drawn (the check above is not '
        'vacuous)', (t) async {
      await background(t, dataPush('c-data', 'Zed', 'drawn by the app'));

      expect(shade.childChats, {'c-data'});
      expect(shade.summaries, hasLength(1));
    });
  });
}
