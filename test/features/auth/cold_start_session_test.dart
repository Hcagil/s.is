// Cold start from the last confirmed session (0.30.15, docs/DECISIONS.md
// 2026-10-04), tested from the contract against fakes of the two boundaries:
// the auth repository (whose server check the test answers, holds, fails or
// answers out of order) and the marker store.
//
// Run under TZ=JST-9 as CI does: the marker's confirmedAt is stored in UTC and
// compared with the phone's clock.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/last_session.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';

import '../../support/last_session_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

final _rigs = <ProviderContainer>[];

/// Disposes every container made in this test, before the binding checks
/// for pending timers (addTearDown runs after that check). A controller that
/// leaves its retry timer running past dispose fails here.
Future<void> end(WidgetTester t) async {
  for (final c in _rigs) {
    c.dispose();
  }
  _rigs.clear();
  await flush(t);
}

class Rig {
  Rig(this.auth, this.store)
    : c = ProviderContainer.test(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(auth),
          lastSessionStoreProvider.overrideWithValue(store),
        ],
      ) {
    _rigs.add(c);
    c.listen(sessionControllerProvider, (_, next) {
      states.add(next);
      if (next.value is Allowed && memberReadsAtFirstAllowed == null) {
        memberReadsAtFirstAllowed = auth.memberReads;
      }
    }, fireImmediately: true);
  }
  final ColdAuth auth;
  final MemoryLastSessionStore store;
  final ProviderContainer c;
  final states = <AsyncValue<SessionState>>[];
  int? memberReadsAtFirstAllowed;

  SessionState? get state => c.read(sessionControllerProvider).value;
  bool get loading => c.read(sessionControllerProvider).isLoading;
  SessionController get ctl => c.read(sessionControllerProvider.notifier);
}

/// Lets queued microtasks and zero-delay hops run, without advancing time.
Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(Duration.zero);
  }
}

Matcher allowed({required bool confirmed}) =>
    isA<Allowed>().having((a) => a.confirmed, 'confirmed', confirmed);

void main() {
  group('optimistic start from a valid marker', () {
    testWidgets('shows Allowed(marker.me, unconfirmed, onboarded) before the '
        'server answers, with no profile read before it', (t) async {
      final auth = ColdAuth(
        member: const Member(userId: 'u1', displayName: 'Maya (server)'),
      );
      final r = Rig(auth, MemoryLastSessionStore(marker()));
      await flush(t);

      expect(r.state, allowed(confirmed: false));
      final a = r.state! as Allowed;
      expect(a.member.displayName, 'Maya', reason: 'not the marker member');
      expect(a.onboarded, isTrue);
      expect(auth.checks, hasLength(1), reason: 'the check was not started');
      expect(auth.checks.single.answered, isFalse);
      expect(r.memberReadsAtFirstAllowed, 0);
      await end(t);
    });

    testWidgets('server says allowed: confirmed, and the marker is rewritten '
        'with a newer confirmedAt', (t) async {
      final old = marker(age: const Duration(days: 3));
      final store = MemoryLastSessionStore(old);
      final r = Rig(ColdAuth(), store);
      await flush(t);
      expect(store.saves, isEmpty, reason: 'saved before the server answered');

      r.auth.last.allow();
      await flush(t);
      expect(r.state, allowed(confirmed: true));
      expect(store.saves, isNotEmpty);
      final saved = store.stored!;
      expect(saved.confirmedAt.isAfter(old.confirmedAt), isTrue);
      expect(
        DateTime.now().toUtc().difference(saved.confirmedAt).abs(),
        lessThan(const Duration(minutes: 1)),
      );
      expect(saved.userId, 'u1');
      expect(saved.sessionId, 'sess-1');
      expect(store.clears, 0);
      await end(t);
    });

    testWidgets(
      'the profile refresh failing after the allow does not undo it',
      (t) async {
        final auth = ColdAuth()
          ..memberResult = const Err(
            NetworkFailure('timeout', retryable: true),
          );
        final r = Rig(auth, MemoryLastSessionStore(marker()));
        await flush(t);
        auth.last.allow();
        await flush(t);
        expect(r.state, allowed(confirmed: true));
        expect(r.store.clears, 0);
        await end(t);
      },
    );

    testWidgets('server says not allowed: Denied in the same turn, before the '
        'marker wipe has finished', (t) async {
      final store = MemoryLastSessionStore(marker())..holdClear();
      final r = Rig(ColdAuth(), store);
      await flush(t);
      expect(r.state, allowed(confirmed: false));

      r.auth.last.deny();
      await flush(t);
      expect(
        r.state,
        isA<Denied>(),
        reason: 'the lock waited for the disk wipe',
      );
      expect(store.clears, greaterThanOrEqualTo(1));
      expect(store.stored, isNull);
      store.releaseClear();
      await flush(t);
      expect(r.state, isA<Denied>());
      await end(t);
    });
  });

  group('an unreachable server', () {
    for (final (name, f) in [
      ('a retryable network error', const NetworkFailure('x', retryable: true)),
      ('a non-retryable server error', const NetworkFailure('500')),
    ]) {
      testWidgets('$name keeps the stored state unconfirmed, flags the notice, '
          'never confirms and never clears', (t) async {
        final store = MemoryLastSessionStore(marker());
        final r = Rig(ColdAuth(), store);
        await flush(t);
        r.auth.last.fail(f);
        await flush(t);
        expect(r.state, allowed(confirmed: false));
        expect(store.saves, isEmpty);
        expect(store.clears, 0);
        await end(t);
      });
    }

    testWidgets('retries on the 2, 4, 8, 16, 32, 60, 60 s ladder', (t) async {
      final r = Rig(ColdAuth(), MemoryLastSessionStore(marker()));
      await flush(t);
      const ladder = [2, 4, 8, 16, 32, 60, 60];
      for (final (i, secs) in ladder.indexed) {
        r.auth.last.fail();
        await flush(t);
        expect(r.auth.checks, hasLength(i + 1));
        await t.pump(Duration(seconds: secs) - const Duration(milliseconds: 1));
        await flush(t);
        expect(
          r.auth.checks,
          hasLength(i + 1),
          reason: 'retry ${i + 1} came before ${secs}s',
        );
        await t.pump(const Duration(milliseconds: 2));
        await flush(t);
        expect(
          r.auth.checks,
          hasLength(i + 2),
          reason: 'retry ${i + 1} not made at ${secs}s',
        );
      }
      expect(r.state, allowed(confirmed: false));
      await end(t);
    });

    testWidgets('a retry answered allowed confirms and clears the notice; a '
        'later retry chain answered not allowed locks', (t) async {
      final store = MemoryLastSessionStore(marker());
      final r = Rig(ColdAuth(), store);
      await flush(t);
      r.auth.last.fail();
      await flush(t);
      await t.pump(const Duration(seconds: 2));
      await flush(t);
      r.auth.last.allow();
      await flush(t);
      expect(r.state, allowed(confirmed: true));
      expect(store.stored, isNotNull);

      // Next cold start: offline, then the member turns out revoked.
      final store2 = MemoryLastSessionStore(store.stored);
      final r2 = Rig(ColdAuth(), store2);
      await flush(t);
      r2.auth.last.fail();
      await flush(t);
      await t.pump(const Duration(seconds: 2));
      await flush(t);
      r2.auth.last.deny();
      await flush(t);
      expect(r2.state, isA<Denied>());
      expect(store2.stored, isNull);
      await end(t);
    });

    testWidgets('recheck() asks at once and resets the ladder to 2 s', (
      t,
    ) async {
      final r = Rig(ColdAuth(), MemoryLastSessionStore(marker()));
      await flush(t);
      // Climb to the 8 s step.
      for (final secs in [2, 4]) {
        r.auth.last.fail();
        await flush(t);
        await t.pump(Duration(seconds: secs));
        await flush(t);
      }
      r.auth.last.fail();
      await flush(t);
      expect(r.auth.checks, hasLength(3));

      r.ctl.recheck();
      await flush(t);
      expect(r.auth.checks, hasLength(4), reason: 'recheck did not ask now');
      r.auth.last.fail();
      await flush(t);
      await t.pump(const Duration(seconds: 2, milliseconds: 1));
      await flush(t);
      expect(r.auth.checks, hasLength(5), reason: 'ladder not reset to 2 s');
      await end(t);
    });

    testWidgets('recheck() does nothing once confirmed', (t) async {
      final r = Rig(ColdAuth(), MemoryLastSessionStore(marker()));
      await flush(t);
      r.auth.last.allow();
      await flush(t);
      r.ctl.recheck();
      await flush(t);
      expect(r.auth.checks, hasLength(1));
      await end(t);
    });
  });

  group('the gated path (today\'s behaviour)', () {
    Future<void> expectGated(WidgetTester t, Rig r) async {
      await flush(t);
      expect(r.state, isNot(isA<Allowed>()), reason: 'optimistic Allowed');
      expect(r.auth.checks, hasLength(1));
      r.auth.last.allow();
      await flush(t);
      expect(r.state, allowed(confirmed: true));
    }

    testWidgets('a marker of another user is deleted', (t) async {
      final store = MemoryLastSessionStore(marker(userId: 'u2'));
      final r = Rig(ColdAuth(), store);
      await flush(t);
      expect(store.clears, greaterThanOrEqualTo(1));
      expect(store.saves, isEmpty);
      await expectGated(t, r);
      expect(store.stored?.userId, anyOf(isNull, 'u1'));
      await end(t);
    });

    testWidgets('a marker of another session id is kept but not trusted', (
      t,
    ) async {
      final store = MemoryLastSessionStore(marker(sessionId: 'sess-0'));
      final r = Rig(ColdAuth(), store);
      await flush(t);
      expect(store.clears, 0, reason: 'a new session id deleted the marker');
      expect(store.stored, isNotNull);
      await expectGated(t, r);
      await end(t);
    });

    testWidgets('a marker older than 14 days is kept but not trusted', (
      t,
    ) async {
      final store = MemoryLastSessionStore(
        marker(age: lastSessionMaxAge + const Duration(minutes: 5)),
      );
      final r = Rig(ColdAuth(), store);
      await flush(t);
      expect(store.clears, 0);
      expect(store.stored, isNotNull);
      await expectGated(t, r);
      await end(t);
    });

    testWidgets('control: a marker just under 14 days is trusted', (t) async {
      final r = Rig(
        ColdAuth(),
        MemoryLastSessionStore(
          marker(age: lastSessionMaxAge - const Duration(minutes: 5)),
        ),
      );
      await flush(t);
      expect(r.state, allowed(confirmed: false));
      await end(t);
    });

    testWidgets('a marker confirmed in the future is not trusted', (t) async {
      final r = Rig(
        ColdAuth(),
        MemoryLastSessionStore(marker(age: const Duration(hours: -2))),
      );
      await expectGated(t, r);
      await end(t);
    });

    testWidgets('a marker of a member not yet onboarded is not trusted', (
      t,
    ) async {
      final r = Rig(
        ColdAuth(),
        MemoryLastSessionStore(marker(onboarded: false)),
      );
      await expectGated(t, r);
      await end(t);
    });

    testWidgets('no marker: gated', (t) async {
      await expectGated(t, Rig(ColdAuth(), MemoryLastSessionStore()));
      await end(t);
    });

    testWidgets('a fresh sign-in is never optimistic, even with a matching '
        'marker on disk', (t) async {
      final store = MemoryLastSessionStore(marker());
      final r = Rig(ColdAuth(session: false), store);
      await flush(t);
      expect(r.state, isA<SignedOut>());
      expect(r.auth.checks, isEmpty);

      store.stored = marker(); // whatever the start did, a marker is there
      unawaited(r.ctl.signIn());
      await flush(t);
      expect(r.state, isNot(isA<Allowed>()));
      expect(r.auth.checks, isNotEmpty);
      r.auth.last.allow();
      await flush(t);
      expect(r.state, allowed(confirmed: true));
      await end(t);
    });

    testWidgets('a store that is not wired (provider throws) is no marker', (
      t,
    ) async {
      final auth = ColdAuth();
      final c = ProviderContainer.test(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(auth),
        ],
      );
      c.listen(sessionControllerProvider, (_, _) {});
      await flush(t);
      expect(c.read(sessionControllerProvider).value, isNot(isA<Allowed>()));
      auth.last.allow();
      await flush(t);
      expect(c.read(sessionControllerProvider).value, allowed(confirmed: true));
      await end(t);
    });
  });

  group('the session ending while unconfirmed', () {
    testWidgets('signed out elsewhere: SignedOut at once (no loading flash), '
        'marker wiped, and the late allow never resurrects Allowed', (t) async {
      final store = MemoryLastSessionStore(marker());
      final r = Rig(ColdAuth(), store);
      await flush(t);
      final before = r.states.length;

      r.auth.endSession();
      await flush(t);
      expect(r.state, isA<SignedOut>());
      expect(
        r.states
            .skip(before)
            .where((s) => s.isLoading || s.value is SessionLoading),
        isEmpty,
        reason: 'a loading state flashed before SignedOut',
      );
      expect(store.stored, isNull);
      expect(store.clears, greaterThanOrEqualTo(1));

      r.auth.checks.first.allow();
      await flush(t);
      expect(r.state, isA<SignedOut>(), reason: 'a superseded answer won');
      expect(
        store.stored,
        isNull,
        reason: 'a superseded answer saved a marker',
      );
      await end(t);
    });

    testWidgets('signOut() wipes the marker', (t) async {
      final store = MemoryLastSessionStore(marker());
      final r = Rig(ColdAuth(autoAllow: true), store);
      await flush(t);
      expect(store.stored, isNotNull);
      unawaited(r.ctl.signOut());
      await flush(t);
      expect(r.state, isA<SignedOut>());
      expect(store.stored, isNull);
      await end(t);
    });

    testWidgets('an older check answering allowed after a newer one answered '
        'not allowed is dropped', (t) async {
      final store = MemoryLastSessionStore(marker());
      final r = Rig(ColdAuth(), store);
      await flush(t);
      final first = r.auth.last;
      r.ctl.recheck();
      await flush(t);
      expect(r.auth.checks, hasLength(2), reason: 'recheck made no new check');

      r.auth.last.deny();
      await flush(t);
      expect(r.state, isA<Denied>());
      first.allow();
      await flush(t);
      expect(
        r.state,
        isA<Denied>(),
        reason: 'the stale allow overwrote Denied',
      );
      expect(store.stored, isNull, reason: 'the stale allow saved a marker');
      await end(t);
    });

    testWidgets('an older check failing after a newer one confirmed does not '
        'raise the notice or schedule retries', (t) async {
      final r = Rig(ColdAuth(), MemoryLastSessionStore(marker()));
      await flush(t);
      final first = r.auth.last;
      r.ctl.recheck();
      await flush(t);
      r.auth.last.allow();
      await flush(t);
      expect(r.state, allowed(confirmed: true));
      first.fail();
      await flush(t);
      await t.pump(const Duration(seconds: 3));
      await flush(t);
      expect(r.auth.checks, hasLength(2));
      expect(r.state, allowed(confirmed: true));
      await end(t);
    });
  });

  group('markOnboarded()', () {
    testWidgets('sets onboarded on the marker without moving confirmedAt', (
      t,
    ) async {
      final store = MemoryLastSessionStore();
      final r = Rig(ColdAuth(autoAllow: true), store);
      await flush(t);
      expect(r.state, allowed(confirmed: true));
      expect(store.stored, isNotNull, reason: 'a confirm saved no marker');
      final at = store.stored!.confirmedAt;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );

      r.ctl.markOnboarded();
      await flush(t);
      expect(store.stored?.onboarded, isTrue);
      expect(store.stored!.confirmedAt, at, reason: 'confirmedAt moved');
      await end(t);
    });
  });
}
