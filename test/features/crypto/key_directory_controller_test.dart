// KeyDirectoryController against fakes of its four collaborators
// (test/support/key_directory_fakes.dart), wired through the same four
// providers main.dart overrides, with the session driven by the test.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import '../../support/container_end.dart';
import '../../support/key_directory_fakes.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');
const _allowed = Allowed(_me);

class _Rig {
  _Rig({String? pickle}) {
    dir = FakeKeyDirectory(log);
    engine = FakeEngine(log);
    store = FakePickleStore(log, pickle);
  }
  final KeyLog log = [];
  late final FakeKeyDirectory dir;
  late final FakeEngine engine;
  late final FakePickleStore store;
  late final ProviderContainer c;
  late final DrivenSession session;

  KeyDirectoryState get state => c.read(keyDirectoryControllerProvider);

  Future<void> start(WidgetTester t, [SessionState s = _allowed]) async {
    c = track(
      ProviderContainer(
        overrides: [
          sessionControllerProvider.overrideWith(
            () => session = DrivenSession(s),
          ),
          keyDirectoryProvider.overrideWithValue(dir),
          keyEngineProvider.overrideWithValue(engine),
          olmPickleStoreProvider.overrideWithValue(store),
          pickleKeyStoreProvider.overrideWithValue(FakePickleKeys()),
        ],
      ),
    );
    c.listen(keyDirectoryControllerProvider, (_, _) {});
    await settle(t);
  }
}

/// Lets every async hop of the fakes and the controller run, without moving
/// the clock.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump();
  }
}

/// A pickle of an account whose [stored] keys were all published.
String publishedPickle({int stored = 50, int id = 1}) {
  final a = FakeAccount([], id)..generateOneTimeKeys(stored);
  a.generateFallbackKey();
  a.markPublished();
  return a.pickle(FakePickleKeys.key);
}

void main() {
  testWidgets('first confirmed sign-in: create+save in one update, publish, '
      'mark+save in another; Ready(50)', (t) async {
    final r = _Rig();
    await r.start(t);

    // The order that matters: the account is created and saved inside one
    // update before anything is published; the publish reads a snapshot in
    // a second update (no save), and a third update restores the STORED
    // account, marks it and saves it.
    expect(r.log.sublist(0, 3), ['status', 'update', 'create']);
    expect(r.log.sublist(3, 5), unorderedEquals(['gen:50', 'fallback']));
    expect(r.log.sublist(5, 13), [
      'save',
      'update',
      'restore',
      'publish:50:fb',
      'update',
      'restore',
      'mark',
      'save',
    ]);
    expect(
      r.log.sublist(13).where((e) => e == 'save' || e.startsWith('gen:')),
      isEmpty,
      reason: 'nothing to refill: no extra save',
    );
    expect(r.store.directSaves, 0, reason: 'every save goes through update');
    expect(r.engine.created, 1);
    final p = r.dir.publishes.single;
    expect(p.identityKey, 'IDENTITY-1');
    expect(p.signingKey, 'SIGNING-1');
    expect(p.oneTimeKeys.toSet(), hasLength(50));
    expect(p.fallbackKey, isNotNull);
    expect(
      p.deviceSignature,
      'sig[1](${deviceStatement('u1', 'IDENTITY-1', 'SIGNING-1')})',
      reason: 'the device signature is the account signing deviceStatement',
    );
    // The pickle saved before publishing holds exactly the keys sent, so a
    // crash after publish re-sends the same set.
    final first = FakeEngine.peek(r.store.savedHistory.first)!;
    expect(first.unpublishedOneTimeKeys, p.oneTimeKeys);
    expect(first.unpublishedFallbackKey, p.fallbackKey);
    // The pickle saved after marking holds no unpublished keys.
    final last = FakeEngine.peek(r.store.saved)!;
    expect(last.unpublishedOneTimeKeys, isEmpty);
    expect(last.unpublishedFallbackKey, isNull);
    expect(r.state, isA<KeysReady>());
    expect((r.state as KeysReady).freeOneTimeKeys, 50);
  });

  testWidgets(
    'second start: restores the pickle and re-publishes an empty list',
    (t) async {
      final r = _Rig(pickle: publishedPickle());
      r.dir.statusAnswers.add(Ok(serverRow()));
      r.dir.publishAnswers.add(const Ok(50));
      await r.start(t);

      expect(r.log, contains('restore'));
      expect(r.log, isNot(contains('create')));
      expect(r.log.where((e) => e.startsWith('gen:')), isEmpty);
      final p = r.dir.publishes.single;
      expect(p.oneTimeKeys, isEmpty);
      expect(p.fallbackKey, isNull);
      expect(p.identityKey, 'IDENTITY-1');
      expect((r.state as KeysReady).freeOneTimeKeys, 50);
    },
  );

  testWidgets('no pickle and a server row of this same session: IdentityLost', (
    t,
  ) async {
    final r = _Rig();
    r.dir.statusAnswers.add(Ok(serverRow(sameSession: true)));
    await r.start(t);

    expect(r.state, isA<KeysIdentityLost>());
    expect(r.log, isNot(contains('create')));
    expect(r.dir.publishes, isEmpty);
    expect(r.store.savedHistory, isEmpty);
  });

  testWidgets(
    'no pickle and a server row of another session (new sign-in): new account',
    (t) async {
      final r = _Rig();
      r.dir.statusAnswers.add(Ok(serverRow(sameSession: false)));
      await r.start(t);

      expect(r.engine.created, 1);
      expect(r.log.sublist(0, 3), ['status', 'update', 'create']);
      final p = r.dir.publishes.single;
      expect(p.oneTimeKeys, hasLength(50));
      expect(p.fallbackKey, isNotNull);
      expect(r.store.savedHistory, isNotEmpty);
      expect(r.store.directSaves, 0);
      expect(
        r.log.indexOf('save'),
        lessThan(r.log.indexOf('publish:50:fb')),
        reason: 'the new account is saved before it is published',
      );
      expect(r.state, isA<KeysReady>());
    },
  );

  testWidgets('a pickle that cannot be read: IdentityLost, no new account', (
    t,
  ) async {
    final r = _Rig(pickle: 'garbled');
    r.dir.statusAnswers.add(Ok(serverRow()));
    await r.start(t);

    expect(r.state, isA<KeysIdentityLost>());
    expect(r.log, isNot(contains('create')));
    expect(r.dir.publishes, isEmpty);
    expect(
      r.store.saved,
      'garbled',
      reason: 'the old pickle is not overwritten',
    );
    expect(r.store.savedHistory, isEmpty);
    expect(r.store.directSaves, 0);
  });

  testWidgets(
    'offline status: Retrying, then retries on the 2 s / 4 s ladder',
    (t) async {
      final r = _Rig();
      r.dir.statusAnswers.addAll(const [
        Err(NetworkFailure('offline', retryable: true)),
        Err(NetworkFailure('offline', retryable: true)),
      ]);
      await r.start(t);
      expect(r.state, isA<KeysRetrying>());
      expect(r.dir.statusCalls, 1);

      await t.pump(sessionRetryDelays[0] - const Duration(milliseconds: 50));
      await settle(t);
      expect(r.dir.statusCalls, 1, reason: 'not before 2 s');
      await t.pump(const Duration(milliseconds: 100));
      await settle(t);
      expect(r.dir.statusCalls, 2, reason: 'once at 2 s');

      await t.pump(sessionRetryDelays[1] - const Duration(milliseconds: 100));
      await settle(t);
      expect(r.dir.statusCalls, 2, reason: 'the second wait is 4 s, not 2 s');
      await t.pump(const Duration(milliseconds: 200));
      await settle(t);
      expect(r.dir.statusCalls, greaterThanOrEqualTo(3));
      expect(r.state, isA<KeysReady>());
      expect(r.engine.created, 1);
    },
  );

  testWidgets('a failed publish is retried with the same unpublished keys', (
    t,
  ) async {
    final r = _Rig();
    r.dir.publishAnswers.add(
      const Err(NetworkFailure('offline', retryable: true)),
    );
    await r.start(t);
    expect(r.state, isA<KeysRetrying>());
    expect(
      r.log,
      isNot(contains('mark')),
      reason: 'nothing is marked after a failed publish',
    );

    await t.pump(sessionRetryDelays[0] + const Duration(milliseconds: 50));
    await settle(t);
    expect(r.dir.publishes, hasLength(2));
    expect(r.dir.publishes[1].oneTimeKeys, r.dir.publishes[0].oneTimeKeys);
    expect(r.dir.publishes[1].fallbackKey, r.dir.publishes[0].fallbackKey);
    expect(
      r.engine.created,
      1,
      reason: 'the retry does not make a new account',
    );
    expect(r.state, isA<KeysReady>());
  });

  testWidgets('a failed pickle save: nothing is published, and it retries', (
    t,
  ) async {
    final r = _Rig();
    r.store.failNext = 1;
    await r.start(t);
    expect(
      r.dir.publishes,
      isEmpty,
      reason: 'keys are never published before the pickle is saved',
    );
    expect(r.state, isA<KeysRetrying>());

    await t.pump(sessionRetryDelays[0] + const Duration(milliseconds: 50));
    await settle(t);
    expect(r.dir.publishes, hasLength(1));
    expect(r.state, isA<KeysReady>());
  });

  testWidgets('a failed update: nothing is published, Retrying', (t) async {
    final r = _Rig();
    r.store.failNextUpdate = 1;
    await r.start(t);
    expect(r.state, isA<KeysRetrying>());
    expect(r.dir.publishes, isEmpty);
    expect(r.store.savedHistory, isEmpty);
  });

  testWidgets('engine.create throws: Retrying, nothing saved, then recovers', (
    t,
  ) async {
    final r = _Rig();
    r.engine.failCreates = 1;
    await r.start(t);
    expect(r.state, isA<KeysRetrying>());
    expect(r.dir.publishes, isEmpty);
    expect(r.store.savedHistory, isEmpty);

    await t.pump(sessionRetryDelays[0] + const Duration(milliseconds: 50));
    await settle(t);
    expect(r.state, isA<KeysReady>());
    expect(r.dir.publishes, hasLength(1));
  });

  testWidgets('a pickle that appeared meanwhile: no new account over it', (
    t,
  ) async {
    final r = _Rig();
    // Another writer stores an account after the status call and before the
    // controller's update reads the store.
    r.store.beforeNextUpdate = () => r.store.saved = publishedPickle(id: 7);
    await r.start(t);

    for (final saved in r.store.savedHistory) {
      expect(FakeEngine.peek(saved)!.id, 7, reason: 'overwritten');
    }
    expect(FakeEngine.peek(r.store.saved)!.id, 7);
    expect(r.log.where((e) => e.startsWith('gen:')), isEmpty);
    expect(
      r.dir.publishes.map((p) => p.identityKey),
      everyElement('IDENTITY-7'),
    );
  });

  testWidgets(
    'a one-time key consumed during publish stays consumed after mark',
    (t) async {
      final r = _Rig();
      final paused = Completer<Result<int>>();
      r.dir.publishAnswers.add(paused.future);
      await r.start(t);
      expect(r.dir.publishes, hasLength(1));
      expect(r.log.last, 'publish:50:fb', reason: 'publish is paused');

      // An inbound session consumes a key through the store meanwhile.
      final inbound = r.store.update((current) async {
        final a =
            await r.engine.restore(current!, FakePickleKeys.key) as FakeAccount;
        a.storedOneTimeKeyCount = 49;
        return a.pickle(FakePickleKeys.key);
      });
      await settle(t);
      expect(await inbound, isTrue);

      paused.complete(const Ok(50));
      await settle(t);
      expect(r.state, isA<KeysReady>());
      final last = FakeEngine.peek(r.store.saved)!;
      expect(last.storedOneTimeKeyCount, 49, reason: 'snapshot saved over it');
      expect(last.unpublishedOneTimeKeys, isEmpty);
      expect(r.store.directSaves, 0);
    },
  );

  testWidgets('DeniedFailure on publish: Idle and no retry', (t) async {
    final r = _Rig();
    r.dir.publishAnswers.add(const Err(DeniedFailure()));
    await r.start(t);
    expect(r.state, isA<KeysIdle>());

    await t.pump(const Duration(seconds: 130));
    await settle(t);
    expect(r.dir.publishes, hasLength(1));
    expect(r.dir.statusCalls, 1);
  });

  testWidgets('DeniedFailure on status: Idle and no retry', (t) async {
    final r = _Rig();
    r.dir.statusAnswers.add(const Err(DeniedFailure()));
    await r.start(t);
    expect(r.state, isA<KeysIdle>());

    await t.pump(const Duration(seconds: 130));
    await settle(t);
    expect(r.dir.statusCalls, 1);
    expect(r.dir.publishes, isEmpty);
  });

  testWidgets(
    'top-up: fewer than half free and room on the phone: fills the room',
    (t) async {
      final r = _Rig(pickle: publishedPickle(stored: 30));
      r.dir.statusAnswers.add(Ok(serverRow(free: 10)));
      r.dir.seedFree(10);
      await r.start(t);

      expect(r.log, contains('gen:20'));
      expect(r.dir.publishes, hasLength(2), reason: 'rebind, then refill');
      expect(r.dir.publishes.first.oneTimeKeys, isEmpty);
      final p = r.dir.publishes.last;
      expect(p.oneTimeKeys, hasLength(20));
      expect(FakeEngine.peek(r.store.saved)!.unpublishedOneTimeKeys, isEmpty);
      expect(r.store.directSaves, 0);
      expect(p.fallbackKey, isNull, reason: 'the fallback was not used');
      expect(r.state, isA<KeysReady>());
    },
  );

  for (final free in [25, 40]) {
    testWidgets('top-up: $free free (half or more): no new keys', (t) async {
      final r = _Rig(pickle: publishedPickle(stored: 30));
      r.dir.statusAnswers.add(Ok(serverRow(free: free)));
      r.dir.seedFree(free);
      await r.start(t);

      expect(r.log.where((e) => e.startsWith('gen:')), isEmpty);
      expect(r.dir.publishes.every((p) => p.oneTimeKeys.isEmpty), isTrue);
      expect(r.dir.publishes, hasLength(1), reason: 'nothing to republish');
      expect(
        r.log.where((e) => e == 'save'),
        hasLength(1),
        reason: 'only the markPublished save',
      );
    });
  }

  testWidgets('top-up: the fallback was used: a new fallback is published', (
    t,
  ) async {
    final r = _Rig(pickle: publishedPickle());
    r.dir.statusAnswers.add(Ok(serverRow(fallbackUsed: true)));
    r.dir.seedFree(50);
    await r.start(t);

    expect(r.log, contains('fallback'));
    expect(r.dir.publishes, hasLength(2));
    expect(r.dir.publishes.last.fallbackKey, isNotNull);
  });

  testWidgets('top-up: the phone already stores the maximum: no generation', (
    t,
  ) async {
    final r = _Rig(pickle: publishedPickle(stored: 50));
    r.dir.statusAnswers.add(Ok(serverRow(free: 10)));
    r.dir.seedFree(10);
    await r.start(t);

    expect(r.log.where((e) => e.startsWith('gen:')), isEmpty);
    expect(r.dir.publishes.every((p) => p.oneTimeKeys.isEmpty), isTrue);
    expect(r.dir.publishes, hasLength(1), reason: 'nothing to republish');
  });

  testWidgets('sign-out cancels the retry timer', (t) async {
    final r = _Rig();
    r.dir.statusAnswers.add(
      const Err(NetworkFailure('offline', retryable: true)),
    );
    await r.start(t);
    expect(r.state, isA<KeysRetrying>());

    r.session.set(const SignedOut());
    await settle(t);
    await t.pump(const Duration(seconds: 130));
    await settle(t);
    expect(r.dir.statusCalls, 1);
    expect(r.state, isA<KeysIdle>());
  });

  testWidgets(
    'sign-out then back in: the old retry never starts a second run',
    (t) async {
      final r = _Rig();
      r.dir.statusAnswers.add(
        const Err(NetworkFailure('offline', retryable: true)),
      );
      await r.start(t);
      r.session.set(const SignedOut());
      await settle(t);
      r.session.set(_allowed);
      await settle(t);
      expect(r.dir.publishes, hasLength(1));
      final calls = r.dir.statusCalls;

      await t.pump(const Duration(seconds: 130));
      await settle(t);
      expect(
        r.dir.statusCalls,
        calls,
        reason: 'the cancelled timer stays silent',
      );
      expect(r.dir.publishes, hasLength(1));
    },
  );

  testWidgets('a late answer after sign-out is ignored', (t) async {
    final r = _Rig();
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.add(late.future);
    await r.start(t);

    r.session.set(const SignedOut());
    await settle(t);
    late.complete(const Ok(null));
    await settle(t);
    expect(r.log, isNot(contains('create')));
    expect(r.dir.publishes, isEmpty);
    expect(r.state, isA<KeysIdle>());
  });

  testWidgets('a late answer after the member changed is ignored', (t) async {
    final r = _Rig();
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.add(late.future);
    await r.start(t);

    r.session.set(const Allowed(Member(userId: 'u2', displayName: 'Ugo')));
    await settle(t);
    late.complete(Ok(serverRow()));
    await settle(t);
    expect(
      r.dir.publishes.map((p) => p.deviceSignature),
      everyElement(contains('|u2|')),
      reason: 'only the new member\'s run may publish',
    );
    expect(
      r.state,
      isNot(isA<KeysIdentityLost>()),
      reason: 'the stale answer for u1 must not decide u2\'s state',
    );
  });

  testWidgets('an unconfirmed Allowed does nothing', (t) async {
    final r = _Rig();
    await r.start(t, const Allowed(_me, confirmed: false));
    await t.pump(const Duration(seconds: 10));
    await settle(t);

    expect(r.log, isEmpty);
    expect(r.state, isA<KeysIdle>());

    r.session.set(_allowed);
    await settle(t);
    expect(
      r.dir.publishes,
      hasLength(1),
      reason: 'the confirmation starts the run',
    );
  });

  testWidgets(
    'claimVerified: a bad device signature is refused, the key never returned',
    (t) async {
      final r = _Rig();
      const keys = ClaimedKeys(
        identityKey: 'IDENTITY-9',
        signingKey: 'SIGNING-9',
        deviceSignature: 'forged',
        oneTimeKey: 'otk-9-0',
        isFallback: false,
      );
      r.dir.claimAnswer = const Ok(keys);
      r.engine.verifyAnswer = false;
      await r.start(t);

      final pending = r.c
          .read(keyDirectoryControllerProvider.notifier)
          .claimVerified('u9');
      await settle(t);
      final got = await pending;
      expect(got, isA<Err<ClaimedKeys?>>());
      final failure = (got as Err<ClaimedKeys?>).failure;
      expect(failure, isA<DeviceKeysFailure>());
      expect(r.engine.verified.single.$1, 'u9');
      expect(r.engine.verified.single.$2, same(keys));
      expect(failure.message, isNot(contains('otk-9-0')));
      expect(failure.message, isNot(contains('IDENTITY-9')));
    },
  );

  testWidgets('claimVerified: a good signature returns the keys', (t) async {
    final r = _Rig();
    const keys = ClaimedKeys(
      identityKey: 'IDENTITY-9',
      signingKey: 'SIGNING-9',
      deviceSignature: 'good',
      oneTimeKey: 'otk-9-0',
      isFallback: false,
    );
    r.dir.claimAnswer = const Ok(keys);
    await r.start(t);

    final pending = r.c
        .read(keyDirectoryControllerProvider.notifier)
        .claimVerified('u9');
    await settle(t);
    final got = await pending;
    expect(got, isA<Ok<ClaimedKeys?>>());
    expect((got as Ok<ClaimedKeys?>).value, same(keys));
    expect(r.dir.claims, ['u9']);
  });

  testWidgets('claimVerified: a refused claim stays an error', (t) async {
    final r = _Rig();
    r.dir.claimAnswer = const Err(DeniedFailure());
    await r.start(t);

    final pending = r.c
        .read(keyDirectoryControllerProvider.notifier)
        .claimVerified('u9');
    await settle(t);
    final got = await pending;
    expect((got as Err).failure, isA<DeniedFailure>());
    expect(r.engine.verified, isEmpty);
  });

  testWidgets('no pickle, key or engine text in any state', (t) async {
    final seen = <String>[];
    final r = _Rig();
    r.dir.publishAnswers.add(
      const Err(NetworkFailure('offline', retryable: true)),
    );
    await r.start(t);
    r.c.listen(
      keyDirectoryControllerProvider,
      (_, s) => seen.add(s.toString()),
    );
    seen.add(r.state.toString());
    await t.pump(sessionRetryDelays[0] + const Duration(milliseconds: 50));
    await settle(t);
    seen.add(r.state.toString());

    final r2 = _Rig(pickle: 'garbled');
    r2.dir.statusAnswers.add(Ok(serverRow()));
    await r2.start(t);
    seen.add(r2.state.toString());

    for (final s in seen) {
      expect(s, isNot(contains('PICKLE')));
      expect(s, isNot(contains('garbled')));
      expect(s, isNot(contains('otk-')));
      expect(s, isNot(contains('fb-')));
      expect(s, isNot(contains('IDENTITY')));
      expect(s, isNot(contains('7, 7')));
    }
    expect(const DeviceKeysFailure().message, isNot(contains('key:')));
  });
}
