// ReactionsController's S5 re-lock of my own plain reaction (a timer shortly
// after the load) must stop cleanly when the chat closes while it waits.
// Stand-ins written from the interfaces only. Contract:
//  * chat closed while TextLocker.lockReaction is pending: when it answers,
//    no uncaught error and relockPlain is never called;
//  * chat closed while ReactionRepository.relockPlain is pending: when it
//    answers, no uncaught error and rememberOwn is never called.
import 'dart:async';

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

import '../../support/fakes.dart';
import '../../support/reaction_fakes.dart';
import '../../support/store_spy.dart' show eventually;
import '../../support/video_fakes.dart' show videoOverrides;

const me = Member(userId: 'u1', displayName: 'Maya');
const ct = 'Q1RfU0VDUkVUX0JZVEVT';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// TextLocker whose lockReaction answers only when the test says so
/// ([pending] null: answers locked at once, after a turn).
class _Locker implements TextLocker {
  final calls = <String>[];
  Completer<Result<QueuedCiphertext?>>? pending;

  @override
  Future<Result<QueuedCiphertext?>> lockReaction({
    required String conversationId,
    required String messageId,
    required String emoji,
  }) async {
    calls.add(messageId);
    final p = pending;
    if (p != null) return p.future;
    await Future<void>.delayed(Duration.zero);
    return const Ok(QueuedCiphertext(ct, 1));
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

class _Opener implements ReactionOpener {
  final remembered = <String>[];

  @override
  Future<List<Reaction>> open(List<Reaction> rows) async => rows;

  @override
  Future<void> rememberOwn(
    String messageId,
    String userId,
    String ciphertext,
    String emoji,
  ) async => remembered.add(messageId);

  @override
  Future<Map<String, int>> ownUsage(String userId) async => const {};
}

enum Close { none, chat, container }

class World {
  World() {
    fake.seed('c1', [
      const Reaction(messageId: 'm1', userId: 'u1', emoji: '❤️'),
    ]);
    c = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(ChatFake()),
        reactionRepositoryProvider.overrideWithValue(fake),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        textLockerProvider.overrideWithValue(locker),
        reactionOpenerProvider.overrideWithValue(opener),
        ...videoOverrides(),
      ],
    );
    addTearDown(dispose);
  }

  var _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    c.dispose();
  }

  final fake = ReactionFake();
  final locker = _Locker();
  final opener = _Opener();
  late final ProviderContainer c;

  Future<void> loaded() async {
    await settled(c);
    c.listen(reactionsProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(reactionsProvider.future);
  }

  void close(Close how) => switch (how) {
    Close.none => null,
    Close.chat => c.read(openConversationProvider.notifier).close(),
    Close.container => dispose(),
  };

  /// Runs every queued hop, then some real time.
  Future<void> after() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

/// Runs [body] in its own zone and returns every uncaught error, including
/// those from timers and futures the controller starts inside it.
Future<List<Object>> uncaught(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body();
    } catch (e) {
      errors.add(e);
    }
    done.complete();
  }, (e, _) => errors.add(e));
  await done.future;
  // Anything still running out of the zone gets a last chance to throw.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return errors;
}

void main() {
  for (final how in [Close.chat, Close.container]) {
    test('closed (${how.name}) while lockReaction is pending: no uncaught '
        'error, relockPlain never called', () async {
      final w = World();
      final p = w.locker.pending = Completer();
      final errors = await uncaught(() async {
        await w.loaded();
        await eventually(
          () => w.locker.calls.isNotEmpty,
          reason: 'the re-lock asked the locker',
        );
        w.close(how);
        p.complete(const Ok(QueuedCiphertext(ct, 1)));
        await w.after();
      });
      expect(errors, isEmpty);
      expect(w.fake.relockCalls, isEmpty);
      expect(w.opener.remembered, isEmpty);
    });

    test('closed (${how.name}) while relockPlain is pending: no uncaught '
        'error, rememberOwn never called', () async {
      final w = World();
      final p = Completer<Result<bool>>();
      w.fake.onRelock = (_, _, _) => p.future;
      final errors = await uncaught(() async {
        await w.loaded();
        await eventually(
          () => w.fake.relockCalls.isNotEmpty,
          reason: 'the re-lock reached the server',
        );
        w.close(how);
        p.complete(const Ok(true));
        await w.after();
      });
      expect(errors, isEmpty);
      expect(w.opener.remembered, isEmpty);
    });
  }

  test('control: left open, the pending lock answers and relockPlain then '
      'rememberOwn run', () async {
    final w = World();
    final p = w.locker.pending = Completer();
    final rp = Completer<Result<bool>>();
    w.fake.onRelock = (_, _, _) => rp.future;
    final errors = await uncaught(() async {
      await w.loaded();
      await eventually(() => w.locker.calls.isNotEmpty, reason: 'lock asked');
      p.complete(const Ok(QueuedCiphertext(ct, 1)));
      await eventually(() => w.fake.relockCalls.isNotEmpty, reason: 'relock');
      rp.complete(const Ok(true));
      await eventually(
        () => w.opener.remembered.isNotEmpty,
        reason: 'the saved copy',
      );
      w.dispose();
    });
    expect(errors, isEmpty);
    expect(w.fake.relockCalls, [('m1', ct, 1)]);
    expect(w.opener.remembered, ['m1']);
  });
}
