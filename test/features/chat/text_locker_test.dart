// TextLocker.lock, every branch of the send-path contract (Private Chats 4a
// Group C): which chats lock, which go plain, and that every failure is an
// Err (the caller then sends NOTHING). Real Riverpod wiring, with fakes for
// the server and the Olm sessions (test/support/encrypted_send_fakes.dart),
// written from the interfaces, never from the implementation.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/text_locker.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/encrypted_send_fakes.dart';
import '../../support/fakes.dart';
import '../../support/key_directory_fakes.dart';
import '../../support/memory_send_queue_store.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

const direct = Conversation(id: 'c1', other: bob);
const hikers = Conversation(id: 'g1', title: 'Hikers', other: bob);
const system = Conversation(id: 's1', isSystem: true, other: bob);
const admin = Conversation(id: 'a1', isAdminChat: true, other: bob);

ClaimedKeys keysOf(String identity, {String otk = ''}) => ClaimedKeys(
  identityKey: identity,
  signingKey: 'sign-$identity',
  deviceSignature: 'sig-$identity',
  oneTimeKey: otk,
  isFallback: false,
);

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
}

/// verifyDevice answers in order (true when the list runs out).
class _Verify extends FakeEngine {
  _Verify(super.log);
  final answers = <bool>[];
  @override
  Future<bool> verifyDevice(String userId, ClaimedKeys keys) async {
    verified.add((userId, keys));
    return answers.isEmpty ? true : answers.removeAt(0);
  }
}

class World {
  World({SessionState session = const Allowed(me), bool wired = true}) {
    chat.conversationsResult = const Ok([direct, hikers, system, admin]);
    dir.identityAnswer = Ok(keysOf('idk-bob'));
    dir.claimAnswer = Ok(keysOf('idk-bob', otk: 'otk-1'));
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(store: queue),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        sessionControllerProvider.overrideWith(() => _Session(session)),
        keyDirectoryProvider.overrideWithValue(dir),
        keyEngineProvider.overrideWithValue(keys),
        queuedCiphertextsProvider.overrideWithValue(queue),
        if (wired) sessionEngineProvider.overrideWithValue(engine),
      ],
    );
  }

  final chat = ChatFake(self: me.userId);
  final log = <String>[];
  late final dir = FakeKeyDirectory(log);
  late final keys = _Verify(log);
  final queue = MemorySendQueueStore();
  late final engine = FakeSessionEngine(queue: queue);
  late final ProviderContainer c;

  Future<Result<QueuedCiphertext?>> lock(
    String conv, {
    String id = 'm1',
    String text = 'hello',
    LinkPreview? card,
    bool queued = false,
  }) async {
    await c.read(sessionControllerProvider.future);
    c.listen(currentUserIdProvider, (_, _) {});
    return c
        .read(textLockerProvider)
        .lock(
          conversationId: conv,
          messageId: id,
          text: text,
          card: card,
          queued: queued,
        );
  }

  /// A session with bob for his current key already exists.
  void session([String key = 'idk-bob']) => engine.sessions['u2'] = {key};
}

Failure? failureOf(Result<Object?> r) => switch (r) {
  Err(:final failure) => failure,
  Ok() => null,
};

QueuedCiphertext? lockedOf(Result<QueuedCiphertext?> r) => switch (r) {
  Ok(:final value) => value,
  Err() => null,
};

void main() {
  test(
    'not wired (no session engine): Ok(null), plain, nothing asked',
    () async {
      final w = World(wired: false);
      final r = await w.lock('c1');
      expect(r, isA<Ok<QueuedCiphertext?>>());
      expect(lockedOf(r), isNull);
      expect(w.dir.identities, isEmpty);
    },
  );

  test('not signed in: Err(Denied)', () async {
    final w = World(session: const SignedOut());
    final r = await w.lock('c1');
    expect(failureOf(r), isA<DeniedFailure>());
    expect(w.engine.encrypts, isEmpty);
  });

  for (final (name, conv) in [
    ('a group', 'g1'),
    ('the system chat', 's1'),
    ('an admin chat', 'a1'),
  ]) {
    test('$name: Ok(null), plain, no key lookup', () async {
      final w = World()..session();
      final r = await w.lock(conv);
      expect(r, isA<Ok<QueuedCiphertext?>>());
      expect(lockedOf(r), isNull);
      expect(w.dir.identities, isEmpty);
      expect(w.engine.encrypts, isEmpty);
    });
  }

  group('a chat missing from the list', () {
    int listReads(World w) =>
        w.chat.calls.where((c) => c == 'conversations').length;

    /// The list is loaded once, so the lock starts from a list that lacks c1.
    Future<void> loadedWithout(World w) async {
      w.chat.conversationsResult = const Ok([hikers]);
      await w.c.read(sessionControllerProvider.future);
      w.c.listen(currentUserIdProvider, (_, _) {});
      w.c.listen(conversationListProvider, (_, _) {});
      await w.c.read(conversationListProvider.future);
      expect(listReads(w), 1, reason: 'setup: the first list read');
    }

    test('present after ONE quiet re-read (a chat just started): locked and '
        'sent to its peer', () async {
      final w = World()..session();
      await loadedWithout(w);
      w.chat.conversationsResult = const Ok([direct, hikers]);
      final r = await w.lock('c1');
      expect(lockedOf(r), isNotNull);
      expect(w.engine.encrypts.single.peer, 'u2');
      expect(listReads(w), 2, reason: 'exactly one re-read');
    });

    test('still missing after the re-read: Err(Denied), never plain, and no '
        'second re-read', () async {
      final w = World()..session();
      await loadedWithout(w);
      final r = await w.lock('nowhere');
      expect(failureOf(r), isA<DeniedFailure>());
      expect(w.engine.encrypts, isEmpty);
      expect(w.dir.identities, isEmpty);
      expect(listReads(w), 2, reason: 'exactly one re-read');
    });
  });

  test('the chat list failed to load: Err(Denied), never plain', () async {
    final w = World()..session();
    w.chat.conversationsResult = const Err(NetworkFailure('No connection'));
    final r = await w.lock('c1');
    expect(failureOf(r), isA<DeniedFailure>());
  });

  test('direct chat with a session: locks the envelope for bob\'s CURRENT '
      'key, the queue row gets the ciphertext', () async {
    final w = World()..session();
    await w.queue.save('u1', [
      QueuedRecord(id: 'm1', conversationId: 'c1', createdAt: DateTime(2026)),
    ]);
    final card = LinkPreview(
      url: Uri.parse('https://e.test/a'),
      title: 'A trail',
      imagePath: 'c1/link-m1.jpg',
    );
    final r = await w.lock('c1', text: 'see 😀', card: card, queued: true);

    final locked = lockedOf(r);
    expect(locked, isNotNull);
    final call = w.engine.encrypts.single;
    expect(call.peer, 'u2');
    expect(call.peerIdentityKey, 'idk-bob');
    expect(
      jsonDecode(call.plaintext),
      jsonDecode(encodeEnvelope(id: 'm1', text: 'see 😀', card: card)),
    );
    expect((call.queue?.userId, call.queue?.queueId), ('u1', 'm1'));
    expect(w.queue.cipher[('u1', 'm1')]?.ciphertext, locked!.ciphertext);
    expect(w.dir.identities, ['u2']);
    expect(w.dir.claims, isEmpty, reason: 'a session exists: no key claimed');
  });

  test('not queued (a forward or an edit): no queue target', () async {
    final w = World()..session();
    final r = await w.lock('c1');
    expect(lockedOf(r), isNotNull);
    expect(w.engine.encrypts.single.queue, isNull);
  });

  test('queued retry: the saved ciphertext comes back as it is; no lookup, '
      'no claim, no new encrypt', () async {
    final w = World()..session();
    await w.queue.save('u1', [
      QueuedRecord(id: 'm1', conversationId: 'c1', createdAt: DateTime(2026)),
    ]);
    w.queue.write('u1', 'm1', 'U0FNRQ', 1);
    final r = await w.lock('c1', queued: true);
    final locked = lockedOf(r);
    expect((locked?.ciphertext, locked?.olmType), ('U0FNRQ', 1));
    expect(w.engine.encrypts, isEmpty);
    expect(w.dir.claims, isEmpty);
  });

  test('a saved ciphertext is NOT reused when not queued', () async {
    final w = World()..session();
    await w.queue.save('u1', [
      QueuedRecord(id: 'm1', conversationId: 'c1', createdAt: DateTime(2026)),
    ]);
    w.queue.write('u1', 'm1', 'U0FNRQ', 1);
    final r = await w.lock('c1');
    expect(lockedOf(r)?.ciphertext, isNot('U0FNRQ'));
    expect(w.engine.encrypts, hasLength(1));
  });

  group('bob\'s keys', () {
    test('signature fails: Err(DeviceKeysFailure), nothing locked', () async {
      final w = World()..session();
      w.keys.answers.add(false);
      final r = await w.lock('c1');
      expect(failureOf(r), isA<DeviceKeysFailure>());
      expect(w.engine.encrypts, isEmpty);
    });

    test('offline: the retryable NetworkFailure comes back as it is', () async {
      final w = World()..session();
      w.dir.identityAnswer = const Err(
        NetworkFailure('No connection', retryable: true),
      );
      final r = await w.lock('c1');
      final f = failureOf(r);
      expect(f, isA<NetworkFailure>());
      expect((f! as NetworkFailure).retryable, isTrue);
    });

    test('not allowed: Err(Denied)', () async {
      final w = World()..session();
      w.dir.identityAnswer = const Err(DeniedFailure());
      expect(failureOf(await w.lock('c1')), isA<DeniedFailure>());
    });

    test('a bot or no published keys: Ok(null), plain', () async {
      final w = World()..session();
      w.dir.identityAnswer = const Ok(null);
      final r = await w.lock('c1');
      expect(r, isA<Ok<QueuedCiphertext?>>());
      expect(lockedOf(r), isNull);
      expect(w.engine.encrypts, isEmpty);
    });
  });

  group('no session yet', () {
    test(
      'claims once, opens a session from the claimed keys, then locks',
      () async {
        final w = World();
        final r = await w.lock('c1');
        expect(lockedOf(r), isNotNull);
        expect(w.dir.claims, ['u2']);
        expect(w.engine.outbound.single.$1, 'u2');
        expect(w.engine.outbound.single.$2.oneTimeKey, 'otk-1');
        expect(w.engine.encrypts, hasLength(2));
        expect(w.engine.encrypts.last.peerIdentityKey, 'idk-bob');
      },
    );

    test(
      'a session only for an OLD key of bob is not used: a new one is made',
      () async {
        final w = World()..session('idk-old');
        final r = await w.lock('c1');
        expect(lockedOf(r), isNotNull);
        expect(w.dir.claims, ['u2']);
      },
    );

    test('claim fails: that Err', () async {
      final w = World();
      w.dir.claimAnswer = const Err(
        NetworkFailure('No connection', retryable: true),
      );
      expect(failureOf(await w.lock('c1')), isA<NetworkFailure>());
      expect(w.engine.outbound, isEmpty);
    });

    test(
      'claim finds no phone: Err(SessionPendingFailure), never plain',
      () async {
        final w = World();
        w.dir.claimAnswer = const Ok(null);
        expect(failureOf(await w.lock('c1')), isA<SessionPendingFailure>());
        expect(w.engine.outbound, isEmpty);
      },
    );

    test('claimed keys fail their signature: Err(DeviceKeysFailure)', () async {
      final w = World();
      w.keys.answers.addAll([true, false]); // identity ok, claim bad
      expect(failureOf(await w.lock('c1')), isA<DeviceKeysFailure>());
      expect(w.engine.outbound, isEmpty);
    });

    test('claim gives ANOTHER identity key than the lookup: '
        'Err(DeviceKeysFailure), no session made', () async {
      final w = World();
      w.dir.claimAnswer = Ok(keysOf('idk-swapped', otk: 'otk-1'));
      expect(failureOf(await w.lock('c1')), isA<DeviceKeysFailure>());
      expect(w.engine.outbound, isEmpty);
    });

    test('opening the session fails: Err', () async {
      final w = World();
      w.engine.outboundAnswers.add(const Err(SessionStoreFailure()));
      expect(failureOf(await w.lock('c1')), isA<SessionStoreFailure>());
    });

    test(
      'still pending after the new session: Err, claimed only once',
      () async {
        final w = World();
        w.engine.encryptAnswers.addAll(const [
          Err(SessionPendingFailure()),
          Err(SessionPendingFailure()),
        ]);
        final r = await w.lock('c1');
        expect(r, isA<Err<QueuedCiphertext?>>());
        expect(w.dir.claims, hasLength(1));
      },
    );
  });

  test('any other encrypt error blocks, with no claim', () async {
    final w = World()..session();
    w.engine.encryptAnswers.add(const Err(SessionStoreFailure()));
    expect(failureOf(await w.lock('c1')), isA<SessionStoreFailure>());
    expect(w.dir.claims, isEmpty);
  });
}
