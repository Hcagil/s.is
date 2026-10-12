// One phone at a time (13b), as main.dart mounts it: SisApp with the real
// session controller, gate, lifecycle observer and push wiring, and fakes
// only at the repository and store boundaries. Written from the contract:
//
// - the old phone notices the replacement at cold start, on resume (even when
//   already confirmed) and through a periodic check about every 10 s; the
//   signal is activate_session answering a clear `false` while a marker is
//   stored. Offline, a timeout or any error is never "replaced";
// - on replacement the Replaced screen shows in the same frame, the device
//   token is forgotten (5 s at most) BEFORE the local sign-out, and every
//   account store is emptied;
// - the screen's button starts Google sign-in; cancelling returns to it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/push.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/file_fakes.dart';
import '../support/last_session_fakes.dart';
import '../support/sticker_fakes.dart';
import '../support/video_fakes.dart';
import '../support/voice_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const bob = Conversation(id: 'c1', lastMessage: 'where are you');
final row = find.byKey(const ValueKey('conversation-c1'));
final home = find.byType(HomeScreen);

const enTitle = 'You signed in on another phone';
const enBody =
    'SIS works on one phone at a time. Sign in again to use it here; the '
    'other phone will be signed out.';
const enButton = 'Sign in';
const trTitle = 'Başka bir telefonda oturum açtın';
const trBody =
    'SIS aynı anda tek telefonda çalışır. Burada kullanmak için yeniden '
    'oturum aç; diğer telefonun oturumu kapanır.';
const trButton = 'Oturum aç';
final deniedText = find.textContaining('not currently approved');

/// Material's phone glyphs, every style.
final phoneIcons = <IconData>{
  Icons.phone_android,
  Icons.phone_android_outlined,
  Icons.phone_android_rounded,
  Icons.phone_android_sharp,
  Icons.smartphone,
  Icons.smartphone_outlined,
  Icons.smartphone_rounded,
  Icons.smartphone_sharp,
  Icons.phone_iphone,
  Icons.phone_iphone_outlined,
  Icons.phone_iphone_rounded,
  Icons.phone_iphone_sharp,
  Icons.mobile_off,
  Icons.mobile_off_outlined,
  Icons.mobile_off_rounded,
  Icons.phonelink_erase,
  Icons.phonelink_erase_outlined,
  Icons.phonelink_erase_rounded,
  Icons.phonelink_lock,
  Icons.phonelink_lock_outlined,
  Icons.phonelink_lock_rounded,
  Icons.mobile_friendly,
  Icons.mobile_friendly_outlined,
  Icons.mobile_friendly_rounded,
};
final phoneIcon = find.byWidgetPredicate(
  (w) => w is Icon && phoneIcons.contains(w.icon),
);

/// Google sign-in the member can cancel.
class CancelAuth extends ColdAuth {
  int signIns = 0;
  bool cancel = true;

  @override
  Future<Result<void>> signInWithGoogle() async {
    signIns++;
    if (cancel) {
      await Future<void>.delayed(Duration.zero);
      return const Err(
        ProviderFailure('Sign-in cancelled', userCanceled: true),
      );
    }
    return super.signInWithGoogle();
  }
}

/// forget_device_token that never answers, as on a dead connection.
class HangingRegistry implements PushRegistry {
  final registered = <String>[];
  final forgotten = <String>[];
  int signOutsAtForget = -1;
  ColdAuth? auth;

  @override
  Future<Result<void>> register(String token) async {
    registered.add(token);
    return const Ok(null);
  }

  @override
  Future<Result<void>> forget(String token) {
    forgotten.add(token);
    signOutsAtForget = auth?.signOuts ?? -1;
    return Completer<Result<void>>().future;
  }
}

class World {
  World({MemoryLastSessionStore? markers, ColdAuth? auth, this.registry})
    : auth = auth ?? CancelAuth(),
      markers = markers ?? MemoryLastSessionStore(marker());
  final ColdAuth auth;
  final MemoryLastSessionStore markers;
  final PushRegistry? registry;
  final snapshot = MemorySnapshotStore(owner: 'u1', list: const [bob]);
  final chat = FakeChat()..conversationsResult = const Ok([bob]);
  final cache = AttachmentCacheFake();
  final files = DeviceFilesFake();
  final played = PlayedVoiceStoreFake({'m1'});
  final stickers = RecentStickerStoreFake(['s1']);
  final source = PushSourceFake();
  final push = PushRegistryFake();
  int? signOutsAtForget;
  bool? sessionAtForget;

  Widget app() {
    push.onForget = (_) {
      signOutsAtForget = auth.signOuts;
      sessionAtForget = auth.session;
    };
    if (registry case final HangingRegistry h) h.auth = auth;
    return ProviderScope(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(auth),
        lastSessionStoreProvider.overrideWithValue(markers),
        chatListSnapshotStoreProvider.overrideWithValue(snapshot),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(
          ProfileFake(
            profile: const OwnProfile(
              userId: 'u1',
              displayName: 'Maya',
              tag: 'maya',
              onboardingDone: true,
            ),
          ),
        ),
        linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
        pushSourceProvider.overrideWithValue(source),
        pushRegistryProvider.overrideWithValue(registry ?? push),
        notificationExplainerStoreProvider.overrideWithValue(
          NotificationExplainerStoreFake(shown: true),
        ),
        attachmentCacheProvider.overrideWithValue(cache),
        deviceFilesProvider.overrideWithValue(files),
        playedVoiceStoreProvider.overrideWithValue(played),
        recentStickerStoreProvider.overrideWithValue(stickers),
      ],
      child: const SisApp(),
    );
  }

  /// Started from the stored marker and confirmed by the server.
  Future<void> confirmed(WidgetTester t) async {
    await t.pumpWidget(app());
    await turns(t);
    auth.last.allow();
    await frames(t);
    expect(row, findsOneWidget, reason: 'setup: the list is not shown');
  }
}

Future<void> turns(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(Duration.zero);
  }
}

Future<void> frames(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Background, then foreground, the way Android reports it.
Future<void> leaveAndReturn(WidgetTester t) async {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    t.binding.handleAppLifecycleStateChanged(s);
    await t.pump();
  }
}

/// The Replaced screen, in English, and nothing of the account behind it.
void expectReplacedScreen(String why) {
  expect(find.text(enTitle), findsOneWidget, reason: why);
  expect(find.text(enBody), findsOneWidget, reason: why);
  expect(find.text(enButton), findsOneWidget, reason: why);
  expect(phoneIcon, findsOneWidget, reason: '$why: no phone icon');
  expect(home, findsNothing, reason: '$why: Home stayed');
  expect(row, findsNothing, reason: '$why: the list stayed');
  expect(deniedText, findsNothing, reason: '$why: Denied shown instead');
}

/// Everything the contract deletes is deleted; the device was forgotten while
/// still signed in, then the phone signed out once.
void expectWiped(World w) {
  expect(w.push.forgotten, ['device-token-1'], reason: 'token not forgotten');
  expect(w.signOutsAtForget, 0, reason: 'signed out before forgetting');
  expect(w.sessionAtForget, isTrue, reason: 'forgot without a session');
  expect(w.auth.signOuts, 1, reason: 'not signed out (once)');
  expect(w.markers.stored, isNull, reason: 'the marker survived');
  expect(w.snapshot.list, isNull, reason: 'the chat list snapshot survived');
  expect(w.cache.clears, greaterThanOrEqualTo(1), reason: 'attachment cache');
  expect(w.files.clears, greaterThanOrEqualTo(1), reason: 'kept files');
  expect(w.played.cleared, isTrue, reason: 'played-voice store');
  expect(w.stickers.cleared, greaterThanOrEqualTo(1), reason: 'stickers');
  expect(w.stickers.ids, isEmpty, reason: 'recent stickers survived');
  expect(w.source.users, contains(null), reason: 'notification inbox kept');
}

void main() {
  testWidgets('cold start: a clear false with a marker shows Replaced in the '
      'same frame, then forgets the token, signs out and wipes', (t) async {
    final w = World();
    await t.pumpWidget(w.app());
    await turns(t);
    expect(row, findsOneWidget, reason: 'setup: stored list not shown');

    w.auth.last.deny();
    await t.pump(const Duration(milliseconds: 1));
    expectReplacedScreen('the frame after the answer');

    await frames(t);
    expectReplacedScreen('after the wipe');
    expectWiped(w);
  });

  testWidgets('resume: an already confirmed session is asked again, and a '
      'false replaces it', (t) async {
    final w = World();
    await w.confirmed(t);
    final before = w.auth.checks.length;

    await leaveAndReturn(t);
    await turns(t);
    expect(w.auth.checks.length, before + 1, reason: 'resume did not ask');
    expect(row, findsOneWidget, reason: 'locked before the answer');

    w.auth.last.deny();
    await t.pump(const Duration(milliseconds: 1));
    expectReplacedScreen('the frame after the answer');
    await frames(t);
    expectWiped(w);
  });

  testWidgets('while open: the server is asked again about every 10 s, and a '
      'false replaces the phone', (t) async {
    final w = World();
    await w.confirmed(t);
    final before = w.auth.checks.length;

    await t.pump(const Duration(seconds: 5));
    await turns(t);
    expect(w.auth.checks.length, before, reason: 'asked well before 10 s');
    await t.pump(const Duration(seconds: 6));
    await turns(t);
    expect(w.auth.checks.length, before + 1, reason: 'no check by 11 s');
    w.auth.last.allow();
    await t.pump(const Duration(seconds: 10));
    await turns(t);
    expect(w.auth.checks.length, before + 2, reason: 'not periodic');
    expect(row, findsOneWidget);

    w.auth.last.deny();
    await t.pump(const Duration(milliseconds: 1));
    expectReplacedScreen('the frame after the periodic answer');
    await frames(t);
    expectWiped(w);
  });

  group('only a clear false counts: the chats stay', () {
    Future<void> noReplacement(WidgetTester t, World w, String why) async {
      await t.pump(const Duration(seconds: 1));
      await frames(t);
      expect(row, findsOneWidget, reason: '$why: the chats went');
      expect(find.text(enTitle), findsNothing, reason: why);
      expect(deniedText, findsNothing, reason: why);
      expect(w.auth.signOuts, 0, reason: '$why: signed out');
      expect(w.push.forgotten, isEmpty, reason: '$why: token forgotten');
      expect(w.markers.stored, isNotNull, reason: '$why: marker wiped');
      expect(w.snapshot.list, isNotNull, reason: '$why: snapshot wiped');
      expect(w.cache.clears, 0, reason: '$why: cache wiped');
      expect(w.files.clears, 0, reason: '$why: kept files wiped');
      expect(w.played.cleared, isFalse, reason: '$why: played wiped');
      expect(w.stickers.cleared, 0, reason: '$why: stickers wiped');
    }

    for (final (name, f) in <(String, Failure)>[
      ('offline', const NetworkFailure('offline', retryable: true)),
      ('a non-retryable network error', const NetworkFailure('refused')),
      ('a denied failure', const DeniedFailure()),
      ('a provider error', const ProviderFailure('boom')),
    ]) {
      testWidgets('the periodic check failing ($name)', (t) async {
        final w = World();
        await w.confirmed(t);
        final before = w.auth.checks.length;
        await t.pump(const Duration(seconds: 11));
        await turns(t);
        expect(w.auth.checks.length, before + 1, reason: 'no periodic check');
        w.auth.last.fail(f);
        await noReplacement(t, w, name);
      });

      testWidgets('the resume check failing ($name)', (t) async {
        final w = World();
        await w.confirmed(t);
        final before = w.auth.checks.length;
        await leaveAndReturn(t);
        await turns(t);
        expect(w.auth.checks.length, before + 1, reason: 'no resume check');
        w.auth.last.fail(f);
        await noReplacement(t, w, name);
      });
    }

    testWidgets('a check that never answers (timeout)', (t) async {
      final w = World();
      await w.confirmed(t);
      await leaveAndReturn(t);
      await turns(t);
      // Never answered; time runs on through several periodic checks.
      await t.pump(const Duration(seconds: 45));
      await noReplacement(t, w, 'timeout');
    });
  });

  testWidgets('forget_device_token never answering holds the sign-out at most '
      '5 s, and the sign-out still comes after it', (t) async {
    final registry = HangingRegistry();
    final w = World(registry: registry);
    await w.confirmed(t);
    expect(registry.registered, ['device-token-1'], reason: 'setup');

    await leaveAndReturn(t);
    await turns(t);
    w.auth.last.deny();
    await t.pump(const Duration(milliseconds: 1));
    expectReplacedScreen('with the forget hanging');
    await turns(t);
    expect(registry.forgotten, ['device-token-1']);
    expect(registry.signOutsAtForget, 0, reason: 'signed out before forget');

    await t.pump(const Duration(seconds: 4));
    await turns(t);
    expect(w.auth.signOuts, 0, reason: 'did not wait for the forget');
    await t.pump(const Duration(milliseconds: 1500));
    await turns(t);
    expect(w.auth.signOuts, 1, reason: 'the 5 s timeout never fired');
    await frames(t);
    expect(w.markers.stored, isNull);
    expectReplacedScreen('after the timeout');
  });

  testWidgets('forget_device_token failing still signs out and wipes', (
    t,
  ) async {
    final w = World();
    w.push.forgetResult = const Err(NetworkFailure('offline'));
    await w.confirmed(t);
    await leaveAndReturn(t);
    await turns(t);
    w.auth.last.deny();
    await frames(t);
    expectReplacedScreen('forget failed');
    expect(w.auth.signOuts, 1);
    expect(w.markers.stored, isNull);
    expect(w.cache.clears, greaterThanOrEqualTo(1));
  });

  testWidgets('Sign in starts Google sign-in at once; cancelling it returns '
      'to the Replaced screen', (t) async {
    final auth = CancelAuth();
    final w = World(auth: auth);
    await t.pumpWidget(w.app());
    await turns(t);
    auth.last.deny();
    await frames(t);
    expectReplacedScreen('setup');

    await t.tap(find.text(enButton));
    await frames(t);
    expect(auth.signIns, 1, reason: 'the button did not start Google sign-in');
    expectReplacedScreen('after cancelling');
    expect(find.text('Continue with Google'), findsNothing);
  });

  testWidgets('Sign in completing on the replaced phone lets the member in', (
    t,
  ) async {
    final auth = CancelAuth()..cancel = false;
    final w = World(auth: auth);
    await t.pumpWidget(w.app());
    await turns(t);
    auth.last.deny();
    await frames(t);
    await t.tap(find.text(enButton));
    await turns(t);
    auth.last.allow();
    await frames(t);
    expect(auth.signIns, 1);
    expect(find.text(enTitle), findsNothing);
    expect(home, findsOneWidget);
  });

  testWidgets('the Replaced screen in Turkish', (t) async {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final w = World();
    await t.pumpWidget(w.app());
    await turns(t);
    w.auth.last.deny();
    await frames(t);
    expect(find.text(trTitle), findsOneWidget);
    expect(find.text(trBody), findsOneWidget);
    expect(find.text(trButton), findsOneWidget);
    expect(phoneIcon, findsOneWidget);
  });

  testWidgets('cold start on the gated path (a stored marker of this account '
      'that cannot stand in for the server): a false is Replaced', (t) async {
    final w = World(markers: MemoryLastSessionStore(marker(onboarded: false)));
    await t.pumpWidget(w.app());
    await turns(t);
    expect(row, findsNothing, reason: 'setup: not the gated path');
    w.auth.last.deny();
    await frames(t);
    expectReplacedScreen('gated');
    expectWiped(w);
  });

  testWidgets('control: a stored marker of another account, a clear false is '
      'Denied, not Replaced', (t) async {
    final w = World(markers: MemoryLastSessionStore(marker(userId: 'u2')));
    await t.pumpWidget(w.app());
    await turns(t);
    w.auth.last.deny();
    await frames(t);
    expect(deniedText, findsOneWidget);
    expect(find.text(enTitle), findsNothing);
  });

  testWidgets('control: no marker, a clear false is Denied (not approved), '
      'not Replaced', (t) async {
    final w = World(markers: MemoryLastSessionStore());
    await t.pumpWidget(w.app());
    await turns(t);
    w.auth.last.deny();
    await frames(t);
    expect(deniedText, findsOneWidget);
    expect(find.text(enTitle), findsNothing);
  });
}
