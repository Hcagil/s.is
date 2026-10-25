// Seam: the message and reaction openers as production mounts them
// (messageOpenerProvider, reactionOpenerProvider, the shared peerKeyCache and
// open queue), with only the edges replaced: identityVerified (the
// KeyDirectoryController method both openers end in), the engine, the stores
// and the signed-in user. Written from the contract, never the implementation.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/catch_up_mark.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/application/reaction_opener.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import '../../support/opener_fakes.dart';
import '../../support/peer_key_fakes.dart';

const bob = 'bob';

class _Me extends CurrentUserId {
  @override
  String? build() => 'me';
  void become(String id) => state = id;
}

class _Keys extends KeyDirectoryController {
  _Keys(this.keys);
  final ControlledKeys keys;
  @override
  KeyDirectoryState build() => const KeysIdle();
  @override
  Future<Result<ClaimedKeys?>> identityVerified(String targetUserId) =>
      keys.call(targetUserId);
}

Message locked(String id, {int t = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: bob,
  body: lockedBodyPlaceholder,
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: t)),
  ciphertext: ct(id),
  olmType: 1,
);

Reaction lockedReaction(String tag) => Reaction(
  messageId: 'm1',
  userId: bob,
  emoji: null,
  ciphertext: ct(tag),
  olmType: 1,
  updatedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late ScriptEngine engine;
  late ControlledKeys keys;

  setUp(() {
    engine = ScriptEngine();
    keys = ControlledKeys();
  });

  void opens(String id) =>
      engine.answer[ct(id)] = () =>
          Ok(encodeEnvelope(id: id, text: 'text $id'));

  ProviderContainer mount() {
    final c = ProviderContainer(
      overrides: [
        currentUserIdProvider.overrideWith(_Me.new),
        keyDirectoryControllerProvider.overrideWith(() => _Keys(keys)),
        sessionEngineProvider.overrideWithValue(engine),
        messageStoreProvider.overrideWithValue(MemoryMessageStore()),
        reactionStoreProvider.overrideWithValue(MemoryReactionStore()),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  T? run<T>(
    FakeAsync a,
    Future<T> f, [
    Duration d = const Duration(seconds: 1),
  ]) {
    T? out;
    f.then((v) => out = v);
    a.elapse(d);
    return out;
  }

  /// A peer's locked reaction is held until a message catch-up pass that
  /// began after its first read ends (CatchUpMark); read it once, then end
  /// such a pass, so the next open really opens it.
  void passGate(FakeAsync a, ProviderContainer c, String tag) {
    run(a, c.read(reactionOpenerProvider).open([lockedReaction(tag)]));
    final mark = c.read(catchUpMarkProvider);
    mark.passDone(mark.stamp());
    keys.calls.clear();
  }

  test('the mounted message opener uses the shared cache: one '
      'identityVerified call for rows of one peer over two opens', () {
    fakeAsync((a) {
      opens('m1');
      opens('m2');
      final c = mount();
      final o = c.read(messageOpenerProvider);
      run(a, o.open([locked('m1')]));
      final out = run(a, o.open([locked('m2', t: 1)]))!;
      expect(out.single.body, 'text m2');
      expect(keys.calls, [bob]);
    });
  });

  test('signed-in user changes: old pending rows are never retried and '
      'the key cache is emptied', () {
    fakeAsync((a) {
      opens('m1');
      opens('m2');
      opens('m3');
      final c = mount();
      final o = c.read(messageOpenerProvider);
      final got = <Message>[];
      o.reopened.listen(got.add);
      run(a, o.open([locked('m2')])); // bob cached
      engine.answer[ct('m1')] = () => const Err(SessionPendingFailure());
      run(a, o.open([locked('m1', t: 1)])); // m1 waits
      opens('m1');
      (c.read(currentUserIdProvider.notifier) as _Me).become('other');
      a.flushMicrotasks();
      final before = engine.calls.length;
      a.elapse(const Duration(minutes: 10));
      expect(engine.calls, hasLength(before), reason: 'old row retried');
      expect(got, isEmpty);
      keys.calls.clear();
      run(a, o.open([locked('m3', t: 2)]));
      expect(keys.calls, [bob], reason: 'key cache kept across accounts');
    });
  });

  test('the reaction opener always fetches fresh, also when the message '
      'opener has the key cached', () {
    fakeAsync((a) {
      opens('m1');
      final c = mount();
      run(a, c.read(messageOpenerProvider).open([locked('m1')]));
      run(a, c.read(reactionOpenerProvider).open([lockedReaction('r1')]));
      expect(keys.calls, [bob, bob]);
    });
  });

  test('a reaction key lookup that never answers ends after about 8 s and '
      'does not hold the queue', () {
    fakeAsync((a) {
      opens('m9');
      final c = mount();
      passGate(a, c, 'r1');
      keys.mode = KeyMode.hang;
      final r = c.read(reactionOpenerProvider).open([lockedReaction('r1')]);
      List<Reaction>? out;
      r.then((v) => out = v);
      a.elapse(const Duration(seconds: 7));
      expect(out, isNull);
      a.elapse(const Duration(seconds: 2));
      expect(out, isNotNull, reason: 'reaction open still waiting at 9 s');
      expect(out!.single.emoji, isNull);
      expect(keys.calls, [bob], reason: 'the lookup was really asked');
      keys.mode = KeyMode.ok;
      final t = run(a, c.read(messageOpenerProvider).open([locked('m9')]))!;
      expect(t.single.body, 'text m9');
    });
  });

  test('a reaction waits behind a text already queued after it', () {
    fakeAsync((a) {
      engine = ScriptEngine(latency: const Duration(milliseconds: 500));
      opens('a1');
      opens('b1');
      final c = mount();
      passGate(a, c, 'r1');
      final texts = c.read(messageOpenerProvider);
      final reactions = c.read(reactionOpenerProvider);
      texts.open([locked('a1')]);
      a.elapse(const Duration(milliseconds: 100)); // a1 is running
      reactions.open([lockedReaction('r1')]);
      texts.open([locked('b1', t: 1)]);
      a.elapse(const Duration(seconds: 10));
      expect(engine.decrypted, [ct('a1'), ct('b1'), ct('r1')]);
    });
  });
}
