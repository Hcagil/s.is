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
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';
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

/// A data-only push, as notify-on-message sends it to this build: addressed
/// to the recipient [to]. Without [to], as a server from before user_id was
/// sent does.
RemoteMessage dataPush(String chat, String title, String body, {String? to}) =>
    RemoteMessage(
      data: {
        'conversation_id': chat,
        'title': title,
        'body': body,
        'user_id': ?to,
      },
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
    await background(
      t,
      dataPush('c-zed', 'Zed', 'Ava secret one', to: ava.userId),
    );
    await background(
      t,
      dataPush('c-yan', 'Yan', 'Ava secret two', to: ava.userId),
    );
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

    await background(
      t,
      dataPush('c-bea', 'Cal', 'first for Bea', to: bea.userId),
    );

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
      await background(t, dataPush('c-xi', 'Xi', 'third', to: ava.userId));
      expect(
        Shade.text(shade.summaries.single),
        contains('3 new messages in 3 chats'),
      );
    });
  });

  group('a start that does not settle who is signed in', () {
    // Only Allowed, SignedOut and Denied say who owns the inbox. A start
    // whose session check fails (offline) says nothing, and must not wipe
    // what arrived for the member while the app was closed.

    SessionState? session(WidgetTester t) =>
        ProviderScope.containerOf(t.element(find.byType(SisApp)))
            .read(sessionControllerProvider)
            .value;

    _android('an offline start keeps the member\'s own notifications, in '
        'the shade and on disk', (t) async {
      final auth = CheckingAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await kill(t);
      await avaPushes(t);

      auth.answer = const Err(NetworkFailure('offline'));
      await launch(t, auth, p);
      expect(session(t), isA<SessionError>(), reason: 'precondition');

      expect(shade.childChats, {'c-zed', 'c-yan'});
      final stored = jsonEncode(disk.values);
      for (final s in ['Ava secret one', 'Ava secret two']) {
        expect(stored, contains(s), reason: 'wiped from disk: $stored');
      }
      await background(t, dataPush('c-xi', 'Xi', 'third', to: ava.userId));
      expect(
        Shade.text(shade.summaries.single),
        contains('3 new messages in 3 chats'),
        reason: 'the waiting ones must still count',
      );
    });
  });

  group('a push delivered late, after the session ended', () {
    // FCM can deliver a push for the previous member after the session
    // ended here. Nobody owns the inbox, so it is never drawn -- and the
    // next start that settles on nobody still finds nothing of it.

    Future<void> latePush(WidgetTester t) async {
      await background(
        t,
        dataPush('c-zed', 'Zed', 'late secret', to: ava.userId),
      );
      expect(shade.posted, isEmpty, reason: 'drawn with nobody signed in');
    }

    void expectLateGone() {
      expect(shade.posted, isEmpty, reason: 'still in the shade');
      final stored = jsonEncode(disk.values);
      for (final s in ['late secret', 'Zed']) {
        expect(stored, isNot(contains(s)), reason: 'kept on disk: $stored');
      }
    }

    _android('is gone once the next start shows sign-in', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('settings-account')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('account-sign-out')));
      await t.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
      await kill(t);
      await latePush(t);

      await launch(t, auth, p);
      expect(find.text('Continue with Google'), findsOneWidget);

      expectLateGone();
    });

    _android('is gone once the next start lands on the Denied screen', (
      t,
    ) async {
      final auth = FakeAuth(session: true, allowed: false, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expect(find.textContaining('not currently approved'), findsOneWidget);
      await kill(t);
      await latePush(t);

      await launch(t, auth, p);
      expect(find.textContaining('not currently approved'), findsOneWidget);

      expectLateGone();
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
      await t.runAsync(() => LocalPushDisplay.forUser(ava.userId));
      await background(
        t,
        dataPush('c-data', 'Zed', 'drawn by the app', to: ava.userId),
      );

      expect(shade.childChats, {'c-data'});
      expect(shade.summaries, hasLength(1));
    });
  });

  group('a push addressed to someone else', () {
    // A push computed for Ava can land after Bea signed in on this phone.
    // It carries user_id = Ava: it must reach neither Bea's shade nor the
    // inbox her summary is built from.

    Future<void> avaSignsOutBeaSignsIn(
      WidgetTester t,
      FakeAuth auth,
      ProfileFake p,
    ) async {
      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('settings-account')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('account-sign-out')));
      await t.pumpAndSettle();
      await beaSignsIn(t, auth, p);
      expect(
        await t.runAsync<String?>(LocalPushDisplay.currentOwner),
        bea.userId,
        reason: 'precondition: Bea owns the inbox',
      );
    }

    _android('Ava\'s push delivered after Bea signed in: not drawn, not '
        'stored, the plugin not even initialised', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      expectHome();
      await avaSignsOutBeaSignsIn(t, auth, p);
      final storedBefore = Map<String, Object>.of(disk.values);
      final mark = shade.calls.length;

      await background(
        t,
        dataPush('c-zed', 'Zed', 'Ava late secret', to: ava.userId),
      );

      expect(shade.posted, isEmpty, reason: 'in Bea\'s shade');
      expect(disk.values, storedBefore, reason: 'stored: ${disk.values}');
      expect(shade.calls.sublist(mark), isEmpty, reason: 'touched the plugin');
      await expectBeaSeesOnlyHers(t, ['Ava late secret', 'Zed']);
    });

    _android('Bea\'s own push, addressed to her, is drawn', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      await avaSignsOutBeaSignsIn(t, auth, p);

      await background(t, dataPush('c-bea', 'Cal', 'for Bea', to: bea.userId));

      expect(shade.childChats, {'c-bea'});
      expect(jsonEncode(disk.values), contains('for Bea'));
    });

    _android('a push without user_id (a server from before it was sent) '
        'still draws for the member signed in', (t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await launch(t, auth, p);
      await avaSignsOutBeaSignsIn(t, auth, p);

      await background(t, dataPush('c-old', 'Cal', 'no address'));

      expect(shade.childChats, {'c-old'});
      expect(jsonEncode(disk.values), contains('no address'));
    });
  });

  group('signed out while offline', () {
    Future<void> lifecycle(WidgetTester t, List<AppLifecycleState> s) async {
      for (final state in s) {
        t.binding.handleAppLifecycleStateChanged(state);
        await t.pump();
      }
      await t.pumpAndSettle();
    }

    // The sign-out happens on this phone, but the server never hears that
    // this device is gone: it keeps sending Ava's previews here.

    Future<(FakeAuth, ProfileFake)> avaSignsOutOffline(WidgetTester t) async {
      final auth = FakeAuth(session: true, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      final registry = PushRegistryFake()
        ..forgetResult = const Err(NetworkFailure('offline'));
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
            pushRegistryProvider.overrideWithValue(registry),
          ],
          child: const SisApp(),
        ),
      );
      await t.pumpAndSettle();
      expectHome();
      await avaPushes(t);
      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('settings-account')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('account-sign-out')));
      await t.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
      return (auth, p);
    }

    _android('a push for Ava arriving afterwards is neither drawn nor '
        'stored', (t) async {
      await avaSignsOutOffline(t);
      expectAvaGone();

      await background(
        t,
        dataPush('c-zed', 'Zed', 'after sign-out secret', to: ava.userId),
      );
      await background(t, dataPush('c-yan', 'Yan', 'unaddressed secret'));

      expect(shade.posted, isEmpty, reason: '${shade.posted}');
      final stored = jsonEncode(disk.values);
      expect(stored, isNot(contains('after sign-out secret')));
      expect(stored, isNot(contains('unaddressed secret')));
    });

    _android('the app coming back to the foreground on the sign-in screen '
        'shows nothing of it', (t) async {
      final (auth, p) = await avaSignsOutOffline(t);
      await lifecycle(t, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);

      await background(
        t,
        dataPush('c-zed', 'Zed', 'while away secret', to: ava.userId),
      );
      await background(t, dataPush('c-yan', 'Yan', 'unaddressed away secret'));

      await lifecycle(t, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(shade.posted, isEmpty, reason: '${shade.posted}');
      expect(jsonEncode(disk.values), isNot(contains('while away secret')));
      expect(jsonEncode(disk.values), isNot(contains('unaddressed away')));

      await beaSignsIn(t, auth, p);
      await expectBeaSeesOnlyHers(t, [
        'while away secret',
        'unaddressed away secret',
        ...avaSecrets,
      ]);
    });
  });

  group('the app shown before any session exists', () {
    // main.dart mounts SisApp without pushSourceProvider in two runs: the
    // config is incomplete (SetupRequired), or startup threw (the startup
    // error screen). Building the push registration there reads the
    // unoverridden provider, which throws UnimplementedError.
    //
    // Under the test binding that error does not surface on its own (it
    // stays inside the provider's error state), so the contract is checked
    // directly as well: the registration is never built, and nothing -- a
    // FlutterError or an uncaught zone error, both of which takeException
    // returns -- was thrown, including after the time Riverpod's retries
    // would take.

    Future<void> expectNothingBuiltOrThrown(WidgetTester t) async {
      await t.pump(const Duration(seconds: 10));
      final c = ProviderScope.containerOf(t.element(find.byType(SisApp)));
      expect(
        c.exists(pushRegistrationProvider),
        isFalse,
        reason: 'the push registration was built',
      );
      expect(c.exists(pushSourceProvider), isFalse);
      final e = t.takeException();
      expect(e, isNot(isA<UnimplementedError>()));
      expect(e, isNull);
    }

    _android('incomplete config: the setup screen, nothing thrown', (t) async {
      // Exactly main.dart's SetupRequired run: no overrides at all.
      await t.pumpWidget(const ProviderScope(child: SisApp()));
      await t.pumpAndSettle();

      expect(find.byType(SetupRequiredScreen), findsOneWidget);
      await expectNothingBuiltOrThrown(t);
    });

    _android('incomplete config: the unoverridden push source is never '
        'asked for, not even before the session is known', (t) async {
      // Stands in for the unoverridden provider: throws exactly what it
      // throws, and counts how often it was made to.
      var thrown = 0;
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            pushSourceProvider.overrideWith((_) {
              thrown++;
              throw UnimplementedError('override in main');
            }),
          ],
          child: const SisApp(),
        ),
      );
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 10));

      expect(find.byType(SetupRequiredScreen), findsOneWidget);
      expect(thrown, 0, reason: 'UnimplementedError thrown $thrown time(s)');
      expect(t.takeException(), isNull);
    });

    for (final withConfig in [false, true]) {
      final name = withConfig
          ? 'with the complete config main.dart had read'
          : 'as main.dart mounts it';
      _android('startup failed ($name): the reason, nothing thrown', (t) async {
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              startupErrorProvider.overrideWithValue('bad secure store'),
              if (withConfig) runtimeConfigProvider.overrideWithValue(config),
            ],
            child: const SisApp(),
          ),
        );
        await t.pumpAndSettle();

        expect(find.byType(StartupFailedScreen), findsOneWidget);
        expect(find.textContaining('bad secure store'), findsOneWidget);
        await expectNothingBuiltOrThrown(t);
      });
    }

    _android('once past SetupRequired, every settled answer reaches the '
        'inbox owner', (t) async {
      await t.runAsync(() => LocalPushDisplay.forUser('member-old'));
      var current = const RuntimeConfig(
        supabaseUrl: '',
        supabasePublishableKey: '',
        googleWebClientId: '',
      );
      final auth = FakeAuth(session: true, allowed: false, member: ava);
      final p = ProfileFake(profile: profileOf(ava));
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            runtimeConfigProvider.overrideWith((_) => current),
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
      expect(find.byType(SetupRequiredScreen), findsOneWidget);
      Future<String?> owner() async =>
          t.runAsync<String?>(LocalPushDisplay.currentOwner);
      expect(
        await owner(),
        'member-old',
        reason: 'SetupRequired settles nobody',
      );

      // The config is complete from here on: the session is asked again.
      current = config;
      final c = ProviderScope.containerOf(t.element(find.byType(SisApp)));
      c.invalidate(runtimeConfigProvider);
      c.invalidate(sessionControllerProvider);
      await t.pumpAndSettle();
      expect(find.textContaining('not currently approved'), findsOneWidget);
      expect(await owner(), isNull, reason: 'Denied must reach forUser');

      await t.tap(find.text('Sign out'));
      await t.pumpAndSettle();
      await beaSignsIn(t, auth, p);
      expect(await owner(), bea.userId, reason: 'Allowed must reach forUser');

      auth.session = false; // the server ends Bea's session
      auth.changes.add(false);
      await t.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(await owner(), isNull, reason: 'SignedOut must reach forUser');
    });
  });
}
