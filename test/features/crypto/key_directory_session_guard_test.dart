// KeyDirectoryController when the session changes while a run is in
// flight: sign-out or a new member during status() or publish(). Same rig
// as key_directory_controller_test.dart.
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
  testWidgets(
    'control: no session change, first sign-in: one publish, KeysReady',
    (t) async {
      final r = _Rig();
      await r.start(t);

      expect(r.dir.publishes, hasLength(1));
      expect(r.log.where((e) => e == 'mark'), hasLength(1));
      expect(r.state, isA<KeysReady>());
    },
  );

  testWidgets(
    'control: sign-out with no new session after Ready: Idle, no exception, sign-in again runs',
    (t) async {
      final r = _Rig();
      await r.start(t);
      expect(r.state, isA<KeysReady>());

      r.session.set(const SignedOut());
      await settle(t);
      expect(r.state, isA<KeysIdle>());
      expect(t.takeException(), isNull);

      r.session.set(_allowed);
      await settle(t);
      expect(r.dir.publishes, hasLength(2));
      expect(r.state, isA<KeysReady>());
    },
  );

  testWidgets(
    'control: sign-out mid-publish, no new session: run ends, a later sign-in runs again',
    (t) async {
      final r = _Rig();
      final paused = Completer<Result<int>>();
      r.dir.publishAnswers.add(paused.future);
      await r.start(t);
      expect(r.dir.publishes, hasLength(1));

      r.session.set(const SignedOut());
      await settle(t);
      paused.complete(const Ok(50));
      await settle(t);
      expect(r.state, isA<KeysIdle>());
      expect(t.takeException(), isNull);

      r.session.set(_allowed);
      await settle(t);
      expect(r.dir.publishes.length, greaterThanOrEqualTo(2));
      expect(r.state, isA<KeysReady>());
    },
  );

  // Case 1: sign-out while dir.status() is pending.

  testWidgets('sign-out during the first status: no account, no publish', (
    t,
  ) async {
    final r = _Rig();
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.add(late.future);
    await r.start(t);
    expect(r.log, ['status']);

    r.session.set(const SignedOut());
    await settle(t);
    late.complete(Ok(serverRow(sameSession: false)));
    await settle(t);
    expect(r.log, ['status'], reason: 'nothing runs for the old user');
    expect(r.dir.publishes, isEmpty);
    expect(r.state, isA<KeysIdle>());
  });

  testWidgets('sign-out during the status after the rebind publish: '
      'no top-up for the old user', (t) async {
    final r = _Rig(pickle: publishedPickle(stored: 30));
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.add(late.future);
    r.dir.seedFree(10);
    await r.start(t);
    expect(r.log.last, 'status', reason: 'status is paused after the rebind');
    expect(r.dir.publishes, hasLength(1));
    final before = r.log.length;

    r.session.set(const SignedOut());
    await settle(t);
    late.complete(Ok(serverRow(free: 10)));
    await settle(t);
    expect(r.log.sublist(before), isEmpty, reason: 'no edit, no publish');
    expect(r.dir.publishes, hasLength(1));
    expect(r.state, isNot(isA<KeysReady>()));
  });

  testWidgets('sign-out during the status after the first publish: '
      'no second publish', (t) async {
    final r = _Rig();
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.addAll([const Ok(null), late.future]);
    await r.start(t);
    expect(r.dir.statusCalls, 2);
    expect(r.dir.publishes, hasLength(1));
    final before = r.log.length;

    r.session.set(const SignedOut());
    await settle(t);
    r.dir.seedFree(0);
    late.complete(Ok(serverRow(free: 0)));
    await settle(t);
    expect(r.log.sublist(before), isEmpty, reason: 'no edit, no publish');
    expect(r.dir.publishes, hasLength(1));
    expect(r.state, isNot(isA<KeysReady>()));
  });

  // Case 2: sign-out during dir.publish(), and just before it.

  testWidgets('sign-out during publish: no mark, keys stay unpublished, '
      'no Ready', (t) async {
    final r = _Rig();
    final paused = Completer<Result<int>>();
    r.dir.publishAnswers.add(paused.future);
    await r.start(t);
    expect(r.log.last, 'publish:50:fb');

    r.session.set(const SignedOut());
    await settle(t);
    paused.complete(const Ok(50));
    await settle(t);
    expect(r.log, isNot(contains('mark')));
    expect(
      FakeEngine.peek(r.store.saved)!.unpublishedOneTimeKeys,
      hasLength(50),
    );
    expect(r.state, isA<KeysIdle>());
  });

  testWidgets('sign-out during a publish that fails: no retry for the old '
      'user', (t) async {
    final r = _Rig();
    final paused = Completer<Result<int>>();
    r.dir.publishAnswers.add(paused.future);
    await r.start(t);

    r.session.set(const SignedOut());
    await settle(t);
    paused.complete(const Err(NetworkFailure('offline', retryable: true)));
    await settle(t);
    expect(r.state, isA<KeysIdle>());
    await t.pump(const Duration(seconds: 130));
    await settle(t);
    expect(r.dir.statusCalls, 1);
    expect(r.dir.publishes, hasLength(1));
    expect(r.state, isA<KeysIdle>());
  });

  testWidgets('sign-out while the keys to publish are read: no publish', (
    t,
  ) async {
    final r = _Rig();
    // Update 1 creates and saves the account; update 2 reads the keys to
    // publish. Sign out inside update 2.
    r.store.beforeNextUpdate = () =>
        r.store.beforeNextUpdate = () => r.session.set(const SignedOut());
    await r.start(t);
    expect(r.log.where((e) => e == 'update'), hasLength(2));
    expect(r.dir.publishes, isEmpty);
    expect(r.log, isNot(contains('mark')));
    expect(r.state, isA<KeysIdle>());
  });

  testWidgets('sign-out while the rebind keys are read: no publish', (t) async {
    final r = _Rig(pickle: publishedPickle());
    r.store.beforeNextUpdate = () => r.session.set(const SignedOut());
    await r.start(t);
    expect(r.log.first, 'update');
    expect(r.dir.publishes, isEmpty);
    expect(r.state, isA<KeysIdle>());
  });

  // Case 3: the member changes from u1 to u2 during a run.

  const u2 = Allowed(Member(userId: 'u2', displayName: 'Ugo'));

  void expectRanForU2(_Rig r, int fromIndex) {
    final after = r.dir.publishes.sublist(fromIndex);
    expect(after, isNotEmpty, reason: 'a pass runs for u2');
    for (final p in after) {
      expect(p.deviceSignature, contains('|u2|'));
    }
    expect(r.state, isA<KeysReady>(), reason: 'not stuck in KeysPublishing');
  }

  testWidgets('u1 -> u2 during the first status: a pass runs for u2', (
    t,
  ) async {
    final r = _Rig();
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.add(late.future);
    await r.start(t);

    r.session.set(u2);
    await settle(t);
    late.complete(const Ok(null));
    await settle(t);
    expectRanForU2(r, 0);
  });

  testWidgets('u1 -> u2 during publish: no mark for u1, a pass runs for u2', (
    t,
  ) async {
    final r = _Rig();
    final paused = Completer<Result<int>>();
    r.dir.publishAnswers.add(paused.future);
    await r.start(t);
    expect(r.dir.publishes.single.deviceSignature, contains('|u1|'));

    r.session.set(u2);
    await settle(t);
    final before = r.log.length;
    paused.complete(const Ok(50));
    await settle(t);
    final after = r.log.sublist(before);
    final firstU2 = after.indexWhere((e) => e.startsWith('publish'));
    expect(firstU2, isNonNegative);
    expect(
      after.sublist(0, firstU2),
      isNot(contains('mark')),
      reason: 'u1\'s publish is not marked after the change',
    );
    expectRanForU2(r, 1);
  });

  testWidgets('u1 -> u2 during the status after the first publish: '
      'a pass runs for u2', (t) async {
    final r = _Rig();
    final late = Completer<Result<PublishedStatus?>>();
    r.dir.statusAnswers.addAll([const Ok(null), late.future]);
    await r.start(t);
    expect(r.dir.publishes, hasLength(1));

    r.session.set(u2);
    await settle(t);
    r.dir.seedFree(0);
    late.complete(Ok(serverRow(free: 0)));
    await settle(t);
    expectRanForU2(r, 1);
  });

  testWidgets('u1 -> u2 while the keys to publish are read: u1 never '
      'publishes, u2 does', (t) async {
    final r = _Rig();
    r.store.beforeNextUpdate = () =>
        r.store.beforeNextUpdate = () => r.session.set(u2);
    await r.start(t);
    await settle(t);
    expectRanForU2(r, 0);
  });

  testWidgets('u1 -> u2 -> signed out during publish: the rerun stops, '
      'nothing more for anyone', (t) async {
    final r = _Rig();
    final paused = Completer<Result<int>>();
    r.dir.publishAnswers.add(paused.future);
    await r.start(t);

    r.session.set(u2);
    await settle(t);
    r.session.set(const SignedOut());
    await settle(t);
    final calls = r.dir.statusCalls;
    paused.complete(const Ok(50));
    await settle(t);
    await t.pump(const Duration(seconds: 130));
    await settle(t);
    expect(r.dir.publishes, hasLength(1), reason: 'no pass after sign-out');
    expect(r.dir.statusCalls, calls);
    expect(r.log, isNot(contains('mark')));
    expect(r.state, isA<KeysIdle>());
    expect(t.takeException(), isNull);
  });
}
