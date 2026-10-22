// The encrypted send path at the controller seam (Private Chats 4a Group C):
// SendQueueController's drain, MessagesController.editMessage and forward,
// wired as production mounts them (same providers), with the REAL TextLocker
// and fakes for the server, the key directory and the Olm sessions. Written
// from the contract, never from the implementation. The rule under test above
// all: a locking failure NEVER sends plain.
//
// testWidgets for its fake clock (the retry ladder).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/text_locker.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart'
    show StoreWriteException;
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/encrypted_send_fakes.dart';
import '../../support/fakes.dart';
import '../../support/key_directory_fakes.dart';
import '../../support/memory_send_queue_store.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const offline = NetworkFailure('No connection', retryable: true);

ClaimedKeys keysOf(String identity, {String otk = ''}) => ClaimedKeys(
  identityKey: identity,
  signingKey: 'sign-$identity',
  deviceSignature: 'sig-$identity',
  oneTimeKey: otk,
  isFallback: false,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// One run of the app. [queue] outlives it, as the on-phone store does.
class App {
  App(this.queue, {this.engine}) {
    engine ??= FakeSessionEngine(queue: queue)..sessions['u2'] = {'idk-bob'};
    chat.conversationsResult = const Ok([
      Conversation(id: 'c1', other: bob),
      Conversation(id: 'g1', title: 'Hikers', other: bob),
    ]);
    dir.identityAnswer = Ok(keysOf('idk-bob'));
    dir.claimAnswer = Ok(keysOf('idk-bob', otk: 'otk-1'));
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(store: queue),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        keyDirectoryProvider.overrideWithValue(dir),
        keyEngineProvider.overrideWithValue(keys),
        queuedCiphertextsProvider.overrideWithValue(queue),
        sessionEngineProvider.overrideWithValue(engine),
        encryptedMessageRepositoryProvider.overrideWithValue(enc),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(currentUserIdProvider, (_, _) {});
    c.listen(sendQueueProvider, (_, _) {});
  }

  final MemorySendQueueStore queue;
  FakeSessionEngine? engine;
  final chat = ChatFake(self: me.userId);
  final log = <String>[];
  late final dir = FakeKeyDirectory(log);
  late final keys = FakeEngine(log);
  final enc = FakeEncryptedMessageRepository(self: me.userId);
  late final ProviderContainer c;

  SendQueueController get q => c.read(sendQueueProvider.notifier);
  List<String> queued(String conv) => [
    for (final m in c.read(sendQueueProvider)[conv] ?? const <Message>[]) m.id,
  ];

  /// Opens [conv] and keeps its messages alive.
  Future<void> open(WidgetTester t, String conv) async {
    c.read(openConversationProvider.notifier).open(conv);
    c.listen(messagesProvider, (_, _) {});
    await hop(t);
  }

  List<Message> shown() => c.read(messagesProvider).value ?? const [];
}

/// Microtasks, zero timers and a little real time for the async fakes.
Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 10; j++) {
      await t.pump();
    }
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

Map<String, Object?> envelopeOf(EncryptCall call) =>
    jsonDecode(call.plaintext) as Map<String, Object?>;

/// An engine whose encrypt waits until [release]: the app can be gone before
/// the lock step answers.
class _GatedEngine extends FakeSessionEngine {
  _GatedEngine({super.queue});
  final _gate = Completer<void>();
  int started = 0;
  void release() => _gate.complete();

  @override
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    required String peerIdentityKey,
    PlaintextSave? save,
    QueueTarget? queue,
  }) async {
    started++;
    await _gate.future;
    return super.encrypt(
      peerUserId,
      plaintext,
      peerIdentityKey: peerIdentityKey,
      save: save,
      queue: queue,
    );
  }
}

void main() {
  group('the app is disposed while a text send waits', () {
    testWidgets('in the save step: no lock, no send, nothing thrown', (
      t,
    ) async {
      final store = MemorySendQueueStore()
        ..saveDelay = const Duration(milliseconds: 100);
      final a = App(store);
      await hop(t);
      a.q.enqueue('c1', body: 'gone');
      await t.pump(const Duration(milliseconds: 10));
      a.c.dispose();
      await t.pump(const Duration(milliseconds: 200));
      await hop(t);
      expect(a.engine!.encrypts, isEmpty, reason: 'locked after dispose');
      expect(a.enc.sends, isEmpty);
      expect(a.chat.sent, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('in the lock step: no send, nothing thrown', (t) async {
      final store = MemorySendQueueStore();
      final engine = _GatedEngine(queue: store)..sessions['u2'] = {'idk-bob'};
      final a = App(store, engine: engine);
      await hop(t);
      a.q.enqueue('c1', body: 'gone');
      await hop(t);
      expect(engine.started, 1, reason: 'setup: the lock step is waiting');
      a.c.dispose();
      engine.release();
      await hop(t);
      expect(a.enc.sends, isEmpty, reason: 'sent after dispose');
      expect(a.chat.sent, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });
  });

  group('drain', () {
    testWidgets('a direct chat with keys: the text leaves ONLY as a '
        'ciphertext, the sender keeps the plaintext', (t) async {
      final a = App(MemorySendQueueStore());
      await hop(t);
      await a.open(t, 'c1');
      final m = a.q.enqueue('c1', body: 'meet at 6');
      await hop(t);

      expect(a.chat.sent, isEmpty, reason: 'a plain send went out');
      final s = a.enc.sends.single;
      expect(s.id, m.id);
      expect(s.conversationId, 'c1');
      expect(
        (s.ciphertext, s.olmType),
        ('Q1QtJHtuXQ1', 0),
        reason: 'not what the engine locked',
      );
      expect(envelopeOf(a.engine!.encrypts.single)['t'], 'meet at 6');
      expect(envelopeOf(a.engine!.encrypts.single)['i'], m.id);
      expect(a.queued('c1'), isEmpty);
      final mine = a.shown().where((x) => x.id == m.id).single;
      expect(mine.body, 'meet at 6', reason: 'the placeholder is shown');
      expect(a.queue.saved, isEmpty, reason: 'the row left with the item');
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a reply carries reply_to on the locked insert', (t) async {
      final a = App(MemorySendQueueStore());
      await hop(t);
      final target = Message(
        id: 'r1',
        conversationId: 'c1',
        senderId: 'u2',
        body: 'when?',
        createdAt: DateTime(2026, 10, 19),
      );
      a.q.enqueue('c1', body: 'at 6', replyTo: target);
      await hop(t);
      expect(a.enc.sends.single.replyTo, 'r1');
      expect(a.chat.sent, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a group chat: the old plain send, nothing locked', (t) async {
      final a = App(MemorySendQueueStore());
      await hop(t);
      a.q.enqueue('g1', body: 'hi all');
      await hop(t);
      expect(a.chat.sent.single.body, 'hi all');
      expect(a.enc.sends, isEmpty);
      expect(a.engine!.encrypts, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    for (final (name, Failure f, void Function(App) arrange) in [
      (
        'keys fail their signature',
        const DeviceKeysFailure(),
        (App a) => a.keys.verifyAnswer = false,
      ),
      (
        'no secure session can be made',
        const SessionPendingFailure(),
        (App a) {
          a.engine!.sessions.clear();
          a.dir.claimAnswer = const Ok(null);
        },
      ),
      (
        'the chat is not in the list',
        const DeniedFailure(),
        (App a) => a.chat.conversationsResult = const Ok([]),
      ),
    ]) {
      testWidgets('locking fails ($name): NOTHING is sent, the queue stops, '
          'the text goes back to the draft with a notice', (t) async {
        final a = App(MemorySendQueueStore());
        arrange(a);
        await hop(t);
        a.q.enqueue('c1', body: 'secret plan');
        await hop(t);
        await t.pump(const Duration(seconds: 10));
        await hop(t);

        expect(a.chat.sent, isEmpty, reason: 'sent PLAIN after $f');
        expect(a.enc.sends, isEmpty);
        expect(a.queued('c1'), isEmpty);
        final drafts = a.c.read(draftsProvider.notifier);
        expect(drafts.draftFor('c1').text, contains('secret plan'));
        expect(drafts.consumeFailure('c1'), isNotNull);
        await t.pump(const Duration(seconds: 30));
      });
    }

    testWidgets('locking offline: queued, retried, never plain', (t) async {
      final a = App(MemorySendQueueStore());
      a.dir.identityAnswer = const Err(offline);
      await hop(t);
      final m = a.q.enqueue('c1', body: 'later');
      await hop(t);
      expect(a.queued('c1'), [m.id]);
      expect(a.c.read(draftsProvider.notifier).consumeFailure('c1'), isNull);
      a.dir.identityAnswer = Ok(keysOf('idk-bob'));
      await t.pump(const Duration(seconds: 1));
      await hop(t);
      expect(a.enc.sends.single.id, m.id);
      expect(a.chat.sent, isEmpty);
      expect(a.queued('c1'), isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    // Group J: the queue row must be saved before the text is locked. When the
    // save fails (StoreWriteException) the send is a retryable failure: nothing
    // leaves, plain or locked, the item stays queued, and a later retry sends it.
    testWidgets('the queue row cannot be saved: nothing sent (never plain), '
        'kept queued, sent locked once the store works', (t) async {
      final store = MemorySendQueueStore()
        ..saveError = const StoreWriteException();
      final a = App(store);
      await hop(t);
      final m = a.q.enqueue('c1', body: 'not yet');
      await hop(t);
      await t.pump(const Duration(seconds: 1));
      await hop(t);
      expect(store.failedSaves, greaterThan(0), reason: 'setup: saves failed');
      expect(a.chat.sent, isEmpty, reason: 'sent PLAIN after a failed save');
      expect(a.enc.sends, isEmpty, reason: 'sent before its row was saved');
      expect(a.queued('c1'), [m.id], reason: 'retryable: stays queued');
      expect(
        a.c.read(draftsProvider.notifier).consumeFailure('c1'),
        isNull,
        reason: 'retryable: not handed back as a failed send',
      );
      store.saveError = null;
      for (var i = 0; i < 6 && a.enc.sends.isEmpty; i++) {
        await t.pump(const Duration(seconds: 5));
        await hop(t);
      }
      expect(a.enc.sends.single.id, m.id, reason: 'the queue retried');
      expect(a.chat.sent, isEmpty);
      expect(a.queued('c1'), isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('the locked insert refused (Denied): queue stops, draft back, '
        'no plain fallback', (t) async {
      final a = App(MemorySendQueueStore());
      a.enc.sendAnswers.add(const Err(DeniedFailure()));
      await hop(t);
      a.q.enqueue('c1', body: 'secret plan');
      await hop(t);
      await t.pump(const Duration(seconds: 10));
      await hop(t);
      expect(a.chat.sent, isEmpty);
      expect(a.enc.sends, hasLength(1));
      expect(a.queued('c1'), isEmpty);
      final drafts = a.c.read(draftsProvider.notifier);
      expect(drafts.draftFor('c1').text, contains('secret plan'));
      expect(drafts.consumeFailure('c1'), isNotNull);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('the locked insert offline: the retry sends the SAME '
        'ciphertext, locked only once', (t) async {
      final a = App(MemorySendQueueStore());
      a.enc.sendAnswers.add(const Err(offline));
      await hop(t);
      final m = a.q.enqueue('c1', body: 'once');
      await hop(t);
      expect(a.queued('c1'), [m.id]);
      expect(
        a.queue.cipher[('u1', m.id)]?.ciphertext,
        a.enc.sends.single.ciphertext,
        reason: 'the ciphertext is kept on the queue row',
      );
      await t.pump(const Duration(seconds: 1));
      await hop(t);
      expect(a.enc.sends, hasLength(2));
      expect(a.enc.sends[1].ciphertext, a.enc.sends[0].ciphertext);
      expect(a.enc.sends[1].olmType, a.enc.sends[0].olmType);
      expect(a.engine!.encrypts, hasLength(1));
      expect(a.chat.sent, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('killed after locking, before the server answered: the next '
        'start resends the SAME ciphertext and locks nothing new', (t) async {
      final store = MemorySendQueueStore();
      final first = App(store);
      first.enc.sendAnswers.add(const Err(offline));
      await hop(t);
      final m = first.q.enqueue('c1', body: 'survives');
      await hop(t);
      final sentBytes = first.enc.sends.single.ciphertext;
      first.c.dispose();
      await t.pump(const Duration(seconds: 30));

      final second = App(store);
      await hop(t);
      await t.pump(const Duration(seconds: 1));
      await hop(t);
      expect(second.enc.sends.single.id, m.id);
      expect(second.enc.sends.single.ciphertext, sentBytes);
      expect(second.engine!.encrypts, isEmpty, reason: 'locked again');
      expect(second.chat.sent, isEmpty);
      expect(store.saved, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });
  });

  testWidgets('a slow store: the queue row is saved BEFORE the text is '
      'locked, so the ciphertext lands on it and a restart reuses it', (
    t,
  ) async {
    final store = MemorySendQueueStore()
      ..saveDelay = const Duration(milliseconds: 100);
    final first = App(store);
    first.enc.sendAnswers.add(const Err(offline));
    await hop(t);
    final m = first.q.enqueue('c1', body: 'slow disk');
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await hop(t);
    }
    expect(first.enc.sends, hasLength(1), reason: 'setup: one attempt');
    final sentBytes = first.enc.sends.single.ciphertext;
    expect(
      store.cipher[('u1', m.id)]?.ciphertext,
      sentBytes,
      reason: 'locked before its row existed: the ciphertext was lost',
    );
    first.c.dispose();
    await t.pump(const Duration(seconds: 30));

    store.saveDelay = Duration.zero;
    final second = App(store);
    await hop(t);
    await t.pump(const Duration(seconds: 1));
    await hop(t);
    expect(second.enc.sends.single.ciphertext, sentBytes);
    expect(second.engine!.encrypts, isEmpty);
    await t.pump(const Duration(seconds: 30));
  });

  group('edit', () {
    Message mine(String id, {String body = lockedBodyPlaceholder}) => Message(
      id: id,
      conversationId: 'c1',
      senderId: me.userId,
      body: body,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );

    testWidgets('a locked chat: edit_message_encrypted with a fresh '
        'ciphertext of the trimmed text and the message\'s own id', (t) async {
      final a = App(MemorySendQueueStore());
      final m = mine('m1');
      a.chat.history['c1'] = [m];
      a.enc.rows['m1'] = m;
      await hop(t);
      await a.open(t, 'c1');

      final r = await a.c
          .read(messagesProvider.notifier)
          .editMessage(m.withPlain('old', null), '  new text  ');
      await hop(t);

      expect(r, isA<Ok<Message>>());
      final e = envelopeOf(a.engine!.encrypts.single);
      expect((e['i'], e['t'], e['lp']), ('m1', 'new text', null));
      expect(a.engine!.encrypts.single.queue, isNull);
      expect(a.enc.edits.single.id, 'm1');
      expect(a.chat.edits, isEmpty, reason: 'a plain edit went out');
      final shownNow = a.shown().where((x) => x.id == 'm1').single;
      expect(shownNow.body, 'new text');
      expect(shownNow.linkPreview, isNull);
      expect(switch (r) {
        Ok(:final value) => value.body,
        Err() => null,
      }, 'new text');
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a plain chat: the old edit_message RPC', (t) async {
      final a = App(MemorySendQueueStore());
      final m = Message(
        id: 'g-m1',
        conversationId: 'g1',
        senderId: me.userId,
        body: 'old',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      a.chat.history['g1'] = [m];
      await hop(t);
      await a.open(t, 'g1');
      final r = await a.c.read(messagesProvider.notifier).editMessage(m, 'new');
      await hop(t);
      expect(r, isA<Ok<Message>>());
      expect(a.chat.edits.single.body, 'new');
      expect(a.enc.edits, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('locking fails: nothing is edited', (t) async {
      final a = App(MemorySendQueueStore());
      a.keys.verifyAnswer = false;
      final m = mine('m1');
      a.chat.history['c1'] = [m];
      a.enc.rows['m1'] = m;
      await hop(t);
      await a.open(t, 'c1');
      final r = await a.c
          .read(messagesProvider.notifier)
          .editMessage(m.withPlain('old', null), 'new');
      await hop(t);
      expect(r, isA<Err<Message>>());
      expect(a.chat.edits, isEmpty);
      expect(a.enc.edits, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('an old PLAIN row in a chat that now locks: Denied, never a '
        'plain edit', (t) async {
      final a = App(MemorySendQueueStore());
      final m = mine('m1', body: 'old plain');
      a.chat.history['c1'] = [m];
      await hop(t);
      await a.open(t, 'c1');
      final r = await a.c.read(messagesProvider.notifier).editMessage(m, 'new');
      await hop(t);
      expect(switch (r) {
        Err(:final failure) => failure,
        Ok() => null,
      }, isA<DeniedFailure>());
      expect(a.chat.edits, isEmpty, reason: 'edited plain into a locked chat');
      await t.pump(const Duration(seconds: 30));
    });
  });

  group('forward', () {
    Message theirs({String body = 'see you there', String? attachmentPath}) =>
        Message(
          id: 'src1',
          conversationId: 'g1',
          senderId: 'u2',
          body: body,
          createdAt: DateTime(2026, 10, 19),
          attachmentPath: attachmentPath,
        );

    Future<App> ready(WidgetTester t) async {
      final a = App(MemorySendQueueStore());
      a.chat.history['g1'] = [theirs()];
      await hop(t);
      await a.open(t, 'g1');
      return a;
    }

    testWidgets('a text into a locked chat: locked with a fresh id, marked '
        'forwarded, no plain forward', (t) async {
      final a = await ready(t);
      final r = await a.c.read(messagesProvider.notifier).forward(theirs(), [
        'c1',
      ]);
      await hop(t);
      expect(r, isA<Ok<void>>());
      final s = a.enc.sends.single;
      expect(s.conversationId, 'c1');
      expect(s.forwarded, isTrue);
      expect(s.id, isNot('src1'));
      final e = envelopeOf(a.engine!.encrypts.single);
      expect((e['i'], e['t']), (s.id, 'see you there'));
      expect(a.engine!.encrypts.single.queue, isNull);
      expect(a.chat.forwarded, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('per target: locked for the direct chat, the old forward for '
        'the group', (t) async {
      final a = await ready(t);
      await a.c.read(messagesProvider.notifier).forward(theirs(), ['c1', 'g1']);
      await hop(t);
      expect([for (final s in a.enc.sends) s.conversationId], ['c1']);
      expect([for (final f in a.chat.forwarded) ...f.conversationIds], ['g1']);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('locking fails: the forward stops, nothing plain', (t) async {
      final a = await ready(t);
      a.keys.verifyAnswer = false;
      final r = await a.c.read(messagesProvider.notifier).forward(theirs(), [
        'c1',
      ]);
      await hop(t);
      expect(r, isA<Err<void>>());
      expect(a.enc.sends, isEmpty);
      expect(a.chat.forwarded, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a photo with a caption: the old forward, even into a locked '
        'chat', (t) async {
      final a = await ready(t);
      await a.c.read(messagesProvider.notifier).forward(
        theirs(body: 'look', attachmentPath: 'g1/p.jpg'),
        ['c1'],
      );
      await hop(t);
      expect(a.enc.sends, isEmpty);
      expect(a.chat.forwarded.single.conversationIds, ['c1']);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a body equal to the placeholder is refused (Denied)', (
      t,
    ) async {
      final a = await ready(t);
      final r = await a.c.read(messagesProvider.notifier).forward(
        theirs(body: lockedBodyPlaceholder),
        ['c1'],
      );
      await hop(t);
      expect(switch (r) {
        Err(:final failure) => failure,
        Ok() => null,
      }, isA<DeniedFailure>());
      expect(a.enc.sends, isEmpty);
      expect(a.chat.forwarded, isEmpty);
      await t.pump(const Duration(seconds: 30));
    });
  });
}
