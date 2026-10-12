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
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/badge_controller.dart';
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

  int appleSignIns = 0;

  /// Apple's sheet, dismissed by the member.
  @override
  Future<Result<void>> signInWithApple() async {
    appleSignIns++;
    await Future<void>.delayed(Duration.zero);
    return const Err(
      ProviderFailure(
        'Sign-in was cancelled. Please try again.',
        userCanceled: true,
      ),
    );
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

/// The send queue as the phone keeps it: per member, until cleared. Notes
/// what had happened elsewhere when it was cleared.
class QueueFake implements SendQueueStore {
  QueueFake(Map<String, int> unsent)
    : saved = {
        for (final MapEntry(:key, :value) in unsent.entries)
          key: [
            for (var i = 0; i < value; i++)
              QueuedRecord(
                id: '$key-q$i',
                conversationId: 'c1',
                createdAt: DateTime(2026, 10, 12, 9, i),
                body: 'unsent $i',
              ),
          ],
      };
  final Map<String, List<QueuedRecord>> saved;
  int clears = 0;
  bool Function() forgotten = () => false;
  int Function() signOuts = () => 0;
  bool? forgottenAtClear;
  int? signOutsAtClear;

  @override
  Future<List<QueuedRecord>> load(String userId) async =>
      List.of(saved[userId] ?? const []);

  @override
  Future<void> save(String userId, List<QueuedRecord> records) async {
    if (records.isEmpty) {
      saved.remove(userId);
    } else {
      saved[userId] = List.of(records);
    }
  }

  @override
  Future<void> clear() async {
    clears++;
    forgottenAtClear ??= forgotten();
    signOutsAtClear ??= signOuts();
    saved.clear();
  }
}

/// The app icon's number, every value set, in order.
class BadgeFake implements AppBadge {
  final sets = <int>[];
  @override
  Future<void> set(int count) async => sets.add(count);
}

/// A server whose forget_device_token answers only when the test says so;
/// every call is logged in arrival order, as the server would apply them.
class LateForgetRegistry implements PushRegistry {
  final log = <String>[];
  final _pending = <Completer<Result<void>>>[];

  void answerForgets() {
    for (final c in _pending) {
      c.complete(const Ok(null));
    }
    _pending.clear();
  }

  @override
  Future<Result<void>> register(String token) async {
    log.add('register $token');
    return const Ok(null);
  }

  @override
  Future<Result<void>> forget(String token) async {
    final c = Completer<Result<void>>();
    _pending.add(c);
    final r = await c.future;
    log.add('forget $token'); // applied on the server when it answers
    return r;
  }
}

class World {
  World({
    MemoryLastSessionStore? markers,
    ColdAuth? auth,
    this.registry,
    Map<String, int> unsent = const {},
  }) : auth = auth ?? CancelAuth(),
       markers = markers ?? MemoryLastSessionStore(marker()),
       queue = QueueFake(unsent);
  final QueueFake queue;
  final badge = BadgeFake();
  final ColdAuth auth;
  final MemoryLastSessionStore markers;
  final PushRegistry? registry;
  final snapshot = MemorySnapshotStore(owner: 'u1', list: const [bob]);
  // Offline for sending: what is queued stays unsent.
  final chat = FakeChat()
    ..conversationsResult = const Ok([bob])
    ..sendResult = const Err(NetworkFailure('offline', retryable: true));
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
    queue.forgotten = () => push.forgotten.isNotEmpty;
    queue.signOuts = () => auth.signOuts;
    return ProviderScope(
      overrides: [
        ...videoOverrides(store: queue),
        appBadgeProvider.overrideWithValue(badge),
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

  group('unsent messages on a replaced phone', () {
    final unsentLine = find.byKey(const ValueKey('replaced-unsent'));

    Future<World> replaced(
      WidgetTester t,
      Map<String, int> unsent, {
      ColdAuth? auth,
    }) async {
      final w = World(unsent: unsent, auth: auth);
      await t.pumpWidget(w.app());
      await turns(t);
      expect(row, findsOneWidget, reason: 'setup: stored list not shown');
      w.auth.last.deny();
      await frames(t);
      return w;
    }

    void expectQueueGoneFirst(World w) {
      expect(w.queue.clears, greaterThanOrEqualTo(1), reason: 'not cleared');
      expect(
        w.queue.saved,
        isEmpty,
        reason: 'the queue survived: ${w.queue.saved.keys}',
      );
      expect(
        w.queue.forgottenAtClear,
        isFalse,
        reason: 'the token was forgotten before the queue was deleted',
      );
      expect(
        w.queue.signOutsAtClear,
        0,
        reason: 'signed out before the queue was deleted',
      );
      expect(w.push.forgotten, ['device-token-1']);
      expect(w.auth.signOuts, 1);
    }

    testWidgets('three unsent: deleted before forget and sign-out, and the '
        'screen says how many (this account only)', (t) async {
      final w = await replaced(t, {'u1': 3, 'u2': 5});
      expectReplacedScreen('with unsent');
      expect(unsentLine, findsOneWidget);
      expect(
        find.text('3 unsent messages were deleted from this phone.'),
        findsOneWidget,
      );
      expectQueueGoneFirst(w);
    });

    testWidgets('one unsent: the singular line', (t) async {
      final w = await replaced(t, {'u1': 1});
      expect(
        find.text('1 unsent message was deleted from this phone.'),
        findsOneWidget,
      );
      expectQueueGoneFirst(w);
    });

    testWidgets('none unsent (another account has some): no line, and the '
        'queue store is still emptied', (t) async {
      final w = await replaced(t, {'u2': 2});
      expectReplacedScreen('no unsent');
      expect(unsentLine, findsNothing);
      expect(find.textContaining('unsent'), findsNothing);
      expectQueueGoneFirst(w);
    });

    testWidgets('Turkish line', (t) async {
      t.platformDispatcher.localesTestValue = [const Locale('tr')];
      addTearDown(t.platformDispatcher.clearLocalesTestValue);
      await replaced(t, {'u1': 2});
      expect(find.text(trTitle), findsOneWidget);
      expect(
        find.text('Bu telefondan gönderilmemiş 2 mesaj silindi.'),
        findsOneWidget,
      );
    });

    testWidgets('backing out of sign-in keeps the same count', (t) async {
      final auth = CancelAuth();
      await replaced(t, {'u1': 4}, auth: auth);
      const line = '4 unsent messages were deleted from this phone.';
      expect(find.text(line), findsOneWidget, reason: 'setup');
      await t.tap(find.text(enButton));
      await frames(t);
      expect(auth.signIns, 1);
      expectReplacedScreen('after cancelling');
      expect(find.text(line), findsOneWidget, reason: 'the count was lost');
    });

    testWidgets('iOS: backing out of Apple sign-in keeps Replaced and the '
        'same count', (t) async {
      final auth = CancelAuth();
      await replaced(t, {'u1': 4}, auth: auth);
      const line = '4 unsent messages were deleted from this phone.';
      final apple = find.byKey(const ValueKey('apple-sign-in'));
      expect(apple, findsOneWidget, reason: 'no Apple button on iOS');
      await t.tap(apple);
      await frames(t);
      expect(auth.appleSignIns, 1, reason: 'the button did not start Apple');
      expect(auth.signIns, 0, reason: 'Google ran instead');
      expectReplacedScreen('after cancelling Apple');
      expect(find.text(line), findsOneWidget, reason: 'the count was lost');
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Android: the Replaced screen has no Apple button', (t) async {
      await replaced(t, {'u1': 1});
      expect(find.byKey(const ValueKey('apple-sign-in')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('resume path counts too', (t) async {
      final w = World(unsent: {'u1': 2});
      await w.confirmed(t);
      await leaveAndReturn(t);
      await turns(t);
      w.auth.last.deny();
      await frames(t);
      expect(
        find.text('2 unsent messages were deleted from this phone.'),
        findsOneWidget,
      );
      expectQueueGoneFirst(w);
    });
  });

  testWidgets('the app icon number goes to 0 on Replaced', (t) async {
    final w = World();
    w.chat.unreadTotalResult = const Ok(4);
    await w.confirmed(t);
    await t.pump(const Duration(seconds: 1)); // the badge read is debounced
    await turns(t);
    expect(
      w.badge.sets,
      contains(4),
      reason: 'setup: the badge never showed 4',
    );
    final before = w.badge.sets.length;
    await leaveAndReturn(t);
    await turns(t);
    w.auth.last.deny();
    await frames(t);
    await t.pump(const Duration(seconds: 1));
    await turns(t);
    expect(
      w.badge.sets.skip(before),
      contains(0),
      reason: 'not cleared on Replaced: ${w.badge.sets}',
    );
    expect(w.badge.sets.last, 0);
  });

  testWidgets('a late forget_device_token never deletes the token the phone '
      'registers after signing in again', (t) async {
    final reg = LateForgetRegistry();
    final auth = CancelAuth()..cancel = false;
    final w = World(auth: auth, registry: reg);
    await w.confirmed(t);
    await t.pump(const Duration(seconds: 1));
    expect(reg.log, ['register device-token-1'], reason: 'setup');

    await leaveAndReturn(t);
    await turns(t);
    auth.last.deny();
    await frames(t);
    await t.pump(const Duration(seconds: 6)); // past the 5 s forget limit
    await frames(t);
    expect(auth.signOuts, 1, reason: 'setup: not signed out');
    expectReplacedScreen('setup');

    // Signs in again while the old forget is still in flight.
    await t.tap(find.text(enButton));
    await turns(t);
    auth.last.allow();
    await frames(t);
    await t.pump(const Duration(seconds: 2));
    expect(home, findsOneWidget, reason: 'setup: not back in');
    expect(reg.log, [
      'register device-token-1',
    ], reason: 'registered while the old forget was still pending');

    reg.answerForgets();
    await frames(t);
    await t.pump(const Duration(seconds: 2));
    expect(reg.log, [
      'register device-token-1',
      'forget device-token-1',
      'register device-token-1',
    ]);
  });
}
