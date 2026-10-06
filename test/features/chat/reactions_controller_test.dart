// ReactionsController (reactionsProvider) against the shared ReactionFake --
// never the SDK. Written from the contract only:
//  * react() applies the change at once and rolls back to the earlier
//    reaction (or none) on Err; the same emoji again is Ok with no call;
//    Err(DeniedFailure) when signed out or not loaded yet; a successful set
//    invalidates reactionUsageProvider;
//  * the Realtime join is not awaited before the load; events arriving before
//    the load answers are buffered;
//  * once the join is confirmed (and the build still live) reactions() is
//    fetched once more after the load: the fetch wins, except for what was
//    applied while it was in flight (live, optimistic, rollback), re-applied
//    on top; a failed re-fetch changes nothing;
//  * a late join after close/switch is cancelled; a late answer (fetch or
//    react) after close/switch is dropped.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/reaction.dart';

import '../../support/fakes.dart';
import '../../support/reaction_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class _SignedOut extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
}

Reaction r(String m, String u, String? e) =>
    Reaction(messageId: m, userId: u, emoji: e);

Future<ProviderContainer> ready(
  ReactionFake fake, {
  bool signedIn = true,
}) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(ChatFake()),
      reactionRepositoryProvider.overrideWithValue(fake),
      sessionControllerProvider.overrideWith(
        signedIn ? _SignedIn.new : _SignedOut.new,
      ),
    ],
  );
  if (signedIn) {
    await settled(c);
  } else {
    await c.read(sessionControllerProvider.future);
  }
  c.listen(reactionsProvider, (_, _) {});
  return c;
}

void open(ProviderContainer c, String id) =>
    c.read(openConversationProvider.notifier).open(id);

/// The state as message -> {(user, emoji)}; empty lists are left out.
Map<String, Set<(String, String?)>> shape(ProviderContainer c) => {
  for (final e in (c.read(reactionsProvider).value ?? const {}).entries)
    if (e.value.isNotEmpty)
      e.key: {for (final x in e.value) (x.userId, x.emoji)},
};

Future<void> until(bool Function() ok, [String what = 'condition']) async {
  for (var i = 0; i < 400; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('timed out waiting for $what');
}

Future<void> turns() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Opens [id] and waits for its first load and the reconcile to settle.
Future<void> loaded(ProviderContainer c, ReactionFake fake, String id) async {
  open(c, id);
  await c.read(reactionsProvider.future);
  await turns();
}

void main() {
  group('load', () {
    test('the open chat\'s reactions, grouped by message', () async {
      final fake = ReactionFake()
        ..seed('c1', [
          r('m1', 'u2', '👍'),
          r('m1', 'u1', '❤️'),
          r('m2', 'u3', '😂'),
        ]);
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      expect(shape(c), {
        'm1': {('u2', '👍'), ('u1', '❤️')},
        'm2': {('u3', '😂')},
      });
    });

    test('a failed initial load is an error state, not a crash', () async {
      final fake = ReactionFake()
        ..onLoad = (_, _) async => const Err(NetworkFailure('down'));
      final c = await ready(fake);
      open(c, 'c1');
      await until(() => c.read(reactionsProvider).hasError, 'error');
      expect(c.read(reactionsProvider).error, isA<NetworkFailure>());
    });

    test('the join is not awaited before the load', () async {
      final join = Completer<void>();
      final fake = ReactionFake()
        ..seed('c1', [r('m1', 'u2', '👍')])
        ..onJoin = (_) => join.future;
      final c = await ready(fake);
      open(c, 'c1');
      // The join never answers here; the load must not wait for it.
      final value = await c
          .read(reactionsProvider.future)
          .timeout(const Duration(seconds: 2));
      expect(value.keys, ['m1']);
      expect(fake.joinCalls, ['c1']);
    });

    test(
      'events arriving before the load answers are buffered, not lost',
      () async {
        final first = Completer<Result<List<Reaction>>>();
        final fake = ReactionFake()
          ..onLoad = (cid, n) => n == 1
              ? first.future
              // The reconcile fails: what is left is load + buffered events.
              : Future.value(const Err(NetworkFailure('down')));
        final c = await ready(fake);
        open(c, 'c1');
        await until(() => fake.listeners('c1') == 1, 'the live listen');
        fake.emit('c1', r('m1', 'u2', '😂'));
        fake.emit('c1', r('m2', 'u3', '👍'));
        fake.emit('c1', r('m2', 'u3', null)); // removed again
        await turns();
        first.complete(Ok([r('m3', 'u4', '🔥'), r('m1', 'u2', '👍')]));
        await c.read(reactionsProvider.future);
        await turns();
        expect(shape(c), {
          'm1': {('u2', '😂')},
          'm3': {('u4', '🔥')},
        });
      },
    );

    test('a live removal arrives as a null emoji and removes it', () async {
      final fake = ReactionFake()
        ..seed('c1', [r('m1', 'u2', '👍'), r('m1', 'u3', '❤️')]);
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      fake.others('c1', r('m1', 'u2', null));
      fake.others('c1', r('m2', 'u3', '🎉'));
      await turns();
      expect(shape(c), {
        'm1': {('u3', '❤️')},
        'm2': {('u3', '🎉')},
      });
    });
  });

  group('react', () {
    test('optimistic: shown before the server answers, kept on Ok', () async {
      final gate = Completer<Result<void>>();
      final fake = ReactionFake()..seed('c1', [r('m1', 'u2', '👍')]);
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      fake.onSet = (_, _) => gate.future;
      final done = c.read(reactionsProvider.notifier).react('m1', '❤️');
      await turns();
      expect(shape(c)['m1'], {('u2', '👍'), ('u1', '❤️')});
      gate.complete(const Ok(null));
      expect(await done, isA<Ok<void>>());
      expect(fake.setCalls, [('m1', '❤️')]);
      expect(shape(c)['m1'], {('u2', '👍'), ('u1', '❤️')});
    });

    test(
      'clear: null removes mine at once, and asks the server to clear',
      () async {
        final fake = ReactionFake()..seed('c1', [r('m1', 'u1', '👍')]);
        final c = await ready(fake);
        await loaded(c, fake, 'c1');
        expect(
          await c.read(reactionsProvider.notifier).react('m1', null),
          isA<Ok<void>>(),
        );
        expect(fake.setCalls, [('m1', null)]);
        expect(shape(c), isEmpty);
      },
    );

    test(
      'Err rolls back to the earlier reaction and returns the failure',
      () async {
        final gate = Completer<Result<void>>();
        final fake = ReactionFake()
          ..seed('c1', [r('m1', 'u1', '❤️'), r('m1', 'u2', '👍')]);
        final c = await ready(fake);
        await loaded(c, fake, 'c1');
        fake.onSet = (_, _) => gate.future;
        final done = c.read(reactionsProvider.notifier).react('m1', '🔥');
        await turns();
        expect(shape(c)['m1'], {('u1', '🔥'), ('u2', '👍')});
        gate.complete(const Err(NetworkFailure('down')));
        final result = await done;
        expect((result as Err<void>).failure, isA<NetworkFailure>());
        expect(shape(c)['m1'], {('u1', '❤️'), ('u2', '👍')});
      },
    );

    test('Err rolls back to none when there was no earlier reaction', () async {
      final fake = ReactionFake()
        ..onSet = (_, _) async => const Err(DeniedFailure());
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      final result = await c.read(reactionsProvider.notifier).react('m1', '👍');
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(shape(c), isEmpty);
    });

    test('the same emoji as mine: Ok with no server call', () async {
      final fake = ReactionFake()..seed('c1', [r('m1', 'u1', '👍')]);
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      final notifier = c.read(reactionsProvider.notifier);
      expect(await notifier.react('m1', '👍'), isA<Ok<void>>());
      expect(await notifier.react('m2', null), isA<Ok<void>>());
      expect(fake.setCalls, isEmpty);
      expect(shape(c), {
        'm1': {('u1', '👍')},
      });
    });

    test('someone else\'s same emoji is not mine: it sets', () async {
      final fake = ReactionFake()..seed('c1', [r('m1', 'u2', '👍')]);
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      await c.read(reactionsProvider.notifier).react('m1', '👍');
      expect(fake.setCalls, [('m1', '👍')]);
    });

    test('signed out: DeniedFailure, no call', () async {
      final fake = ReactionFake(me: null);
      final c = await ready(fake, signedIn: false);
      open(c, 'c1');
      await turns();
      final result = await c.read(reactionsProvider.notifier).react('m1', '👍');
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(fake.setCalls, isEmpty);
    });

    test('not loaded yet: DeniedFailure, no call, nothing applied', () async {
      final fake = ReactionFake()
        ..onLoad = (_, _) => Completer<Result<List<Reaction>>>().future;
      final c = await ready(fake);
      open(c, 'c1');
      await turns();
      final result = await c.read(reactionsProvider.notifier).react('m1', '👍');
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(fake.setCalls, isEmpty);
    });

    test(
      'a successful set refreshes the usage; a failed one does not',
      () async {
        final fake = ReactionFake();
        final c = await ready(fake);
        c.listen(reactionUsageProvider, (_, _) {});
        await c.read(reactionUsageProvider.future);
        await loaded(c, fake, 'c1');
        expect(fake.usageCalls, 1);

        await c.read(reactionsProvider.notifier).react('m1', '👍');
        await until(() => fake.usageCalls == 2, 'usage refetch');
        expect(await c.read(reactionUsageProvider.future), {'👍': 1});

        fake.onSet = (_, _) async => const Err(NetworkFailure('down'));
        await c.read(reactionsProvider.notifier).react('m1', '❤️');
        await turns();
        expect(fake.usageCalls, 2);
      },
    );
  });

  group('reconcile after the join', () {
    test('the second fetch wins when it differs', () async {
      final join = Completer<void>();
      final fake = ReactionFake()
        ..seed('c1', [r('m1', 'u2', '👍'), r('m2', 'u3', '😂')])
        ..onJoin = (_) => join.future;
      final c = await ready(fake);
      open(c, 'c1');
      await c.read(reactionsProvider.future);
      await turns();
      expect(fake.loadsOf('c1'), 1, reason: 'no re-fetch before the join');
      // The server moved on while the join was pending, silently.
      fake.seed('c1', [r('m1', 'u2', '❤️'), r('m4', 'u5', '🎉')]);
      join.complete();
      await until(() => fake.loadsOf('c1') == 2, 'the re-fetch');
      await turns();
      expect(shape(c), {
        'm1': {('u2', '❤️')},
        'm4': {('u5', '🎉')},
      });
      await turns();
      expect(fake.loadsOf('c1'), 2, reason: 'once');
    });

    test(
      'a join confirmed before the load: the re-fetch comes after it',
      () async {
        final first = Completer<Result<List<Reaction>>>();
        final fake = ReactionFake()..seed('c1', [r('m1', 'u2', '👍')]);
        fake.onLoad = (cid, n) =>
            n == 1 ? first.future : Future.value(fake.snapshot(cid));
        final c = await ready(fake);
        open(c, 'c1');
        await until(() => fake.listeners('c1') == 1, 'the join');
        await turns();
        expect(fake.loadsOf('c1'), 1);
        first.complete(const Ok([]));
        await c.read(reactionsProvider.future);
        await until(() => fake.loadsOf('c1') == 2, 'the re-fetch');
        await turns();
        expect(shape(c), {
          'm1': {('u2', '👍')},
        });
      },
    );

    test('what lands during the fetch is re-applied on top: live, '
        'optimistic and rollback', () async {
      final refetch = Completer<Result<List<Reaction>>>();
      final join = Completer<void>();
      final fake = ReactionFake()
        ..seed('c1', [r('m4', 'u1', '❤️'), r('m6', 'u6', '😀')])
        ..onJoin = (_) => join.future;
      fake.onLoad = (cid, n) =>
          n == 1 ? Future.value(fake.snapshot(cid)) : refetch.future;
      final c = await ready(fake);
      open(c, 'c1');
      await c.read(reactionsProvider.future);
      join.complete();
      await until(() => fake.loadsOf('c1') == 2, 'the re-fetch');

      // While the re-fetch is out:
      fake.emit('c1', r('m2', 'u2', '😂')); // live
      final notifier = c.read(reactionsProvider.notifier);
      expect(await notifier.react('m3', '👍'), isA<Ok<void>>()); // optimistic
      fake.onSet = (_, _) async => const Err(NetworkFailure('down'));
      expect(await notifier.react('m4', '🔥'), isA<Err<void>>()); // rollback
      await turns();

      // The fetch answers with a snapshot taken before all of that.
      refetch.complete(Ok([r('m4', 'u1', '😮'), r('m5', 'u7', '👏')]));
      await turns();
      expect(shape(c), {
        'm2': {('u2', '😂')},
        'm3': {('u1', '👍')},
        'm4': {('u1', '❤️')},
        'm5': {('u7', '👏')},
      });
    });

    test('a failed re-fetch changes nothing', () async {
      final fake = ReactionFake()..seed('c1', [r('m1', 'u2', '👍')]);
      fake.onLoad = (cid, n) => Future.value(
        n == 1 ? fake.snapshot(cid) : const Err(NetworkFailure('down')),
      );
      final c = await ready(fake);
      open(c, 'c1');
      await c.read(reactionsProvider.future);
      await until(() => fake.loadsOf('c1') == 2, 'the re-fetch');
      await turns();
      expect(c.read(reactionsProvider).hasError, isFalse);
      expect(shape(c), {
        'm1': {('u2', '👍')},
      });
    });
  });

  group('close and switch', () {
    test('a join that answers after a switch is cancelled, and never '
        're-fetches the old chat', () async {
      final joinC1 = Completer<void>();
      final fake = ReactionFake()
        ..seed('c1', [r('m1', 'u2', '👍')])
        ..seed('c2', [r('m9', 'u3', '😂')])
        ..onJoin = (cid) => cid == 'c1' ? joinC1.future : Future.value();
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      await loaded(c, fake, 'c2');
      joinC1.complete();
      await turns();
      expect(fake.listeners('c1'), 0, reason: 'the late c1 feed is dropped');
      fake.emit('c1', r('m1', 'u2', '🔥'));
      await turns();
      expect(fake.loadsOf('c1'), 1);
      expect(shape(c), {
        'm9': {('u3', '😂')},
      });
    });

    test('a join that answers after the chat closed is cancelled', () async {
      final join = Completer<void>();
      final fake = ReactionFake()..onJoin = (_) => join.future;
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      c.read(openConversationProvider.notifier).close();
      await turns();
      join.complete();
      await turns();
      expect(fake.listeners('c1'), 0);
      expect(fake.loadsOf('c1'), 1);
    });

    test('switching cancels the old live feed', () async {
      final fake = ReactionFake();
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      expect(fake.listeners('c1'), 1);
      await loaded(c, fake, 'c2');
      expect(fake.listeners('c1'), 0);
      expect(fake.listeners('c2'), 1);
    });

    test('a load answering after a switch is dropped', () async {
      final c1 = Completer<Result<List<Reaction>>>();
      final fake = ReactionFake()..seed('c2', [r('m9', 'u3', '😂')]);
      fake.onLoad = (cid, n) =>
          cid == 'c1' ? c1.future : Future.value(fake.snapshot(cid));
      final c = await ready(fake);
      open(c, 'c1');
      await turns();
      await loaded(c, fake, 'c2');
      c1.complete(Ok([r('m1', 'u2', '👍')]));
      await turns();
      expect(shape(c), {
        'm9': {('u3', '😂')},
      });
    });

    test('a re-fetch answering after a switch is dropped', () async {
      final refetch = Completer<Result<List<Reaction>>>();
      final fake = ReactionFake()
        ..seed('c1', [r('m1', 'u2', '👍')])
        ..seed('c2', [r('m9', 'u3', '😂')]);
      fake.onLoad = (cid, n) => cid == 'c1' && n == 2
          ? refetch.future
          : Future.value(fake.snapshot(cid));
      final c = await ready(fake);
      open(c, 'c1');
      await c.read(reactionsProvider.future);
      await until(() => fake.loadsOf('c1') == 2, 'the c1 re-fetch');
      await loaded(c, fake, 'c2');
      refetch.complete(Ok([r('m1', 'u2', '🔥'), r('m8', 'u4', '👀')]));
      await turns();
      expect(shape(c), {
        'm9': {('u3', '😂')},
      });
    });

    test('a react answer after a switch is dropped: no rollback into the '
        'new chat', () async {
      final gate = Completer<Result<void>>();
      final fake = ReactionFake()
        ..seed('c1', [r('m1', 'u1', '❤️')])
        ..seed('c2', [r('m9', 'u3', '😂')]);
      final c = await ready(fake);
      await loaded(c, fake, 'c1');
      fake.onSet = (_, _) => gate.future;
      final done = c.read(reactionsProvider.notifier).react('m1', '🔥');
      await turns();
      await loaded(c, fake, 'c2');
      gate.complete(const Err(NetworkFailure('down')));
      await done;
      await turns();
      expect(shape(c), {
        'm9': {('u3', '😂')},
      });
    });
  });
}
