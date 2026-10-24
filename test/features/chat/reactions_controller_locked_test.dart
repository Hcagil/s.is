// ReactionsController.react in a private chat, against the shared ReactionFake
// and stand-ins for TextLocker and ReactionOpener written from their
// interfaces, never from the implementation. Contract:
//  * a clear is always the plain set_reaction(NULL), never locked;
//  * a set asks TextLocker.lockReaction first:
//      Ok(null)  -> plain setReaction (the chat takes a plain reaction);
//      Err       -> returned, rolled back, NOTHING sent (no plain fallback);
//      locked    -> setLockedReaction, and rememberOwn of those bytes; a
//                   failed try never replaces the earlier saved copy and
//                   never adds to the usage counts ((b), RED-EXPECTED);
//  * one retry on a retryable NetworkFailure, with the very same bytes; any
//    other failure (or a second one) rolls back;
//  * nothing logs the emoji or the ciphertext.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/reaction_opener.dart';
import 'package:sis/features/chat/application/text_locker.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/reaction_opener.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';

import 'package:sis/features/chat/data/store/drift_reaction_store.dart';

import '../../support/fakes.dart';
import '../../support/reaction_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness;

const me = Member(userId: 'u1', displayName: 'Maya');
const ct = 'Q1RfU0VDUkVUX0JZVEVT';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// TextLocker stand-in: answers lockReaction from [answers] (default: locked
/// to [ct], type 1), always after a turn.
class _Locker implements TextLocker {
  _Locker(this.log);
  final List<String> log;
  final calls = <(String, String, String)>[];
  final answers = <Result<QueuedCiphertext?>>[];
  Result<QueuedCiphertext?> Function()? onLock;

  @override
  Future<Result<QueuedCiphertext?>> lockReaction({
    required String conversationId,
    required String messageId,
    required String emoji,
  }) async {
    calls.add((conversationId, messageId, emoji));
    log.add('lock');
    await Future<void>.delayed(Duration.zero);
    if (answers.isNotEmpty) return answers.removeAt(0);
    return onLock?.call() ?? const Ok(QueuedCiphertext(ct, 1));
  }

  @override
  Future<Result<QueuedCiphertext?>> lock({
    required String conversationId,
    required String messageId,
    required String text,
    LinkPreview? card,
    bool queued = false,
  }) => throw StateError('a reaction must never lock as a message');
}

/// ReactionOpener stand-in: rows pass unchanged; rememberOwn is recorded.
class _Opener implements ReactionOpener {
  _Opener(this.log);
  final List<String> log;
  final remembered = <(String, String, String, String)>[];

  @override
  Future<List<Reaction>> open(List<Reaction> rows) async => rows;

  @override
  Future<void> rememberOwn(
    String messageId,
    String userId,
    String ciphertext,
    String emoji,
  ) async {
    await Future<void>.delayed(Duration.zero);
    remembered.add((messageId, userId, ciphertext, emoji));
    log.add('remember');
  }

  @override
  Future<Map<String, int>> ownUsage(String userId) async => const {};
}

class World {
  World({ReactionOpener? realOpener}) {
    fake
      ..seed('c1', [const Reaction(messageId: 'm1', userId: 'u1', emoji: '❤️')])
      ..onSetLocked = (m, x, t) async {
        log.add('rpc');
        await Future<void>.delayed(Duration.zero);
        return lockedAnswers.isEmpty
            ? const Ok(null)
            : lockedAnswers.removeAt(0);
      };
    c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(ChatFake()),
        reactionRepositoryProvider.overrideWithValue(fake),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        textLockerProvider.overrideWithValue(locker),
        reactionOpenerProvider.overrideWithValue(realOpener ?? opener),
      ],
    );
  }

  final log = <String>[];
  final fake = ReactionFake();
  late final locker = _Locker(log);
  late final opener = _Opener(log);
  final lockedAnswers = <Result<void>>[];
  late final ProviderContainer c;

  Future<void> loaded() async {
    await settled(c);
    c.listen(reactionsProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(reactionsProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<Result<void>> react(String? emoji) =>
      c.read(reactionsProvider.notifier).react('m1', emoji);

  /// My reaction on m1 as the state shows it.
  String? mine() => [
    for (final x
        in c.read(reactionsProvider).value?['m1'] ?? const <Reaction>[])
      if (x.userId == 'u1') x.emoji,
  ].firstOrNull;
}

Failure? failureOf(Result<void> r) => switch (r) {
  Err(:final failure) => failure,
  Ok() => null,
};

/// Runs [body] with print and debugPrint captured.
Future<List<String>> logsOf(Future<void> Function() body) async {
  final lines = <String>[];
  final saved = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
  try {
    await runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
  } finally {
    debugPrint = saved;
  }
  return lines;
}

void main() {
  test('a locked set: lockReaction once, rememberOwn of the sent bytes, '
      'setLockedReaction with those bytes, no plain set', () async {
    final w = World();
    await w.loaded();
    final r = await w.react('👍');
    expect(r, isA<Ok<void>>());
    expect(w.locker.calls, [('c1', 'm1', '👍')]);
    expect(w.opener.remembered, [('m1', 'u1', ct, '👍')]);
    expect(w.fake.lockedCalls, [('m1', ct, 1)]);
    expect(w.log.first, 'lock');
    expect(w.fake.setCalls, isEmpty, reason: 'no plain copy of the emoji');
    expect(w.mine(), '👍');
  });

  test('Ok(null) from the locker (plain chat): plain setReaction, '
      'nothing locked or remembered', () async {
    final w = World();
    w.locker.answers.add(const Ok(null));
    await w.loaded();
    expect(await w.react('👍'), isA<Ok<void>>());
    expect(w.fake.setCalls, [('m1', '👍')]);
    expect(w.fake.lockedCalls, isEmpty);
    expect(w.opener.remembered, isEmpty);
  });

  for (final f in <Failure>[
    const DeniedFailure(),
    const NetworkFailure('no keys', retryable: true),
  ]) {
    test('a locking Err (${f.runtimeType}) is returned and rolled back; '
        'nothing is sent, never a plain fallback', () async {
      final w = World();
      w.locker.answers.add(Err(f));
      await w.loaded();
      final r = await w.react('👍');
      expect(failureOf(r), same(f));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(w.fake.setCalls, isEmpty);
      expect(w.fake.lockedCalls, isEmpty);
      expect(w.locker.calls, hasLength(1), reason: 'no re-lock');
      expect(w.mine(), '❤️', reason: 'rolled back to the earlier reaction');
    });
  }

  test(
    'a retryable NetworkFailure is retried once with the very same bytes',
    () async {
      final w = World();
      w.lockedAnswers.add(
        const Err(NetworkFailure('offline', retryable: true)),
      );
      await w.loaded();
      expect(await w.react('👍'), isA<Ok<void>>());
      expect(w.fake.lockedCalls, [('m1', ct, 1), ('m1', ct, 1)]);
      expect(w.locker.calls, hasLength(1), reason: 'not locked again');
      expect(w.fake.setCalls, isEmpty);
      expect(w.mine(), '👍');
    },
  );

  test('a second retryable failure: Err, rolled back, two calls only, '
      'no plain fallback', () async {
    final w = World();
    w.lockedAnswers.addAll([
      const Err(NetworkFailure('offline', retryable: true)),
      const Err(NetworkFailure('offline', retryable: true)),
    ]);
    await w.loaded();
    final r = await w.react('👍');
    expect(failureOf(r), isA<NetworkFailure>());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(w.fake.lockedCalls, hasLength(2));
    expect(w.fake.setCalls, isEmpty);
    expect(w.mine(), '❤️');
  });

  for (final f in <Failure>[
    const DeniedFailure(),
    const NetworkFailure('bad request'),
  ]) {
    test('a non-retryable RPC failure (${f.runtimeType}): one call, '
        'rolled back, no plain fallback', () async {
      final w = World();
      w.lockedAnswers.add(Err(f));
      await w.loaded();
      final r = await w.react('👍');
      expect(failureOf(r), same(f));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(w.fake.lockedCalls, hasLength(1));
      expect(w.fake.setCalls, isEmpty);
      expect(w.mine(), '❤️');
    });
  }

  test('a clear is the plain set_reaction(NULL), never locked', () async {
    final w = World();
    await w.loaded();
    expect(await w.react(null), isA<Ok<void>>());
    expect(w.fake.setCalls, [('m1', null)]);
    expect(w.locker.calls, isEmpty);
    expect(w.fake.lockedCalls, isEmpty);
    expect(w.mine(), isNull);
  });

  test(
    'nothing logs the emoji or the ciphertext (set, retry, failure)',
    () async {
      final w = World();
      w.lockedAnswers.addAll([
        const Err(NetworkFailure('offline', retryable: true)),
        const Err(DeniedFailure()),
      ]);
      final lines = await logsOf(() async {
        await w.loaded();
        await w.react('🦄');
        await w.react('🦄');
        w.locker.answers.add(const Err(DeniedFailure()));
        await w.react('🐙');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(w.fake.lockedCalls, isNotEmpty, reason: 'the path ran');
      for (final l in lines) {
        expect(l, isNot(contains('🦄')));
        expect(l, isNot(contains('🐙')));
        expect(l, isNot(contains(ct)));
      }
    },
  );

  group('S5: own plain reactions in a private chat are re-locked by this '
      'build (RED-EXPECTED until the fix round)', () {
    test('opening the private chat re-locks my plain reaction with the same '
        'emoji; another member\'s plain row is left alone', () async {
      final w = World();
      w.fake.seed('c1', [
        const Reaction(messageId: 'm1', userId: 'u1', emoji: '❤️'),
        const Reaction(messageId: 'm2', userId: 'u2', emoji: '😂'),
      ]);
      await w.loaded();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(w.locker.calls, contains(('c1', 'm1', '❤️')));
      expect(w.fake.lockedCalls, contains(('m1', ct, 1)));
      expect([for (final c in w.locker.calls) c.$2], isNot(contains('m2')));
      expect(w.fake.setCalls, isEmpty, reason: 'no plain re-send');
    });

    test('control: in a plain chat (locker answers Ok(null)) nothing is '
        're-sent', () async {
      final w = World();
      for (var i = 0; i < 5; i++) {
        w.locker.answers.add(const Ok(null));
      }
      await w.loaded();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(w.fake.lockedCalls, isEmpty);
      expect(w.fake.setCalls, isEmpty);
    });
  });

  group('(b) with the REAL opener over a REAL store', () {
    late StoreHarness h;
    late DriftReactionStore store;

    setUp(() async {
      h = await StoreHarness.create();
      final s = h.open(owner: 'u1', key: await h.newKey());
      addTearDown(s.close);
      store = DriftReactionStore(s);
    });

    /// A world whose opener is the production one (own rows come from the
    /// store only) and whose locker hands out a new ciphertext per lock.
    Future<(World, StoreReactionOpener)> world() async {
      final real = StoreReactionOpener(
        me: () => 'u1',
        engine: () => null,
        store: () => store,
        peerKey: (_) async => const Ok(null),
      );
      final w = World(realOpener: real);
      var n = 0;
      w.locker.onLock = () => Ok(QueuedCiphertext('Q1Q${++n}', 1));
      await w.loaded();
      return (w, real);
    }

    Reaction own(String ciphertext) => Reaction(
      messageId: 'm1',
      userId: 'u1',
      emoji: null,
      ciphertext: ciphertext,
      olmType: 1,
    );

    test('a failed change keeps the earlier saved copy and the usage counts '
        '(RED-EXPECTED until the fix round)', () async {
      final (w, opener) = await world();
      expect(await w.react('👍'), isA<Ok<void>>());
      expect((await opener.open([own('Q1Q1')])).single.emoji, '👍');
      expect(await opener.ownUsage('u1'), {'👍': 1});

      w.lockedAnswers.add(const Err(DeniedFailure()));
      expect(failureOf(await w.react('❤️')), isA<DeniedFailure>());
      // The server still holds Q1Q1: it must still open to 👍.
      expect(
        (await opener.open([own('Q1Q1')])).single.emoji,
        '👍',
        reason:
            'the earlier good copy was overwritten before the server '
            'accepted the change',
      );
      expect(await opener.ownUsage('u1'), {
        '👍': 1,
      }, reason: 'a failed try added to the usage counts');
    });

    test('a first set that fails leaves no usage behind '
        '(RED-EXPECTED until the fix round)', () async {
      final (w, opener) = await world();
      w.lockedAnswers.add(const Err(DeniedFailure()));
      expect(failureOf(await w.react('🦊')), isA<DeniedFailure>());
      expect(await opener.ownUsage('u1'), isEmpty);
    });

    test('control: an accepted change replaces the copy', () async {
      final (w, opener) = await world();
      expect(await w.react('👍'), isA<Ok<void>>());
      expect(await w.react('❤️'), isA<Ok<void>>());
      expect((await opener.open([own('Q1Q2')])).single.emoji, '❤️');
      expect(await opener.ownUsage('u1'), {'❤️': 1});
    });
  });
}
