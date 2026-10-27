// StoreReactionOpener with TWO REAL Olm engines (OlmKeyEngine over the
// compiled vodozemac library) and REAL encrypted store files, with the real
// DriftReactionStore. Real Olm cannot open one message twice, so "opens once"
// is checked by the engine itself and by a counting wrapper. Written from the
// ReactionOpener / ReactionStore / SessionEngine contracts, never from the
// implementation:
//  * a locked row opens to its emoji once, is saved, and later reads (a new
//    opener too) come from the store;
//  * the envelope is bound to the row's message and reactor (E1), and a
//    message envelope never opens as a reaction;
//  * a row that cannot be opened comes back with emoji null, never text;
//  * own rows are never decrypted: shown only from rememberOwn;
//  * locked rows open oldest first; nothing logs emoji or ciphertext;
//  * F1: a chat's locked messages and reactions share one queue, reactions
//    after messages, so a burst of > 40 messages still opens;
//  * F3: every locked reaction has the same ciphertext length;
//  * R1 (CatchUpMark): a PEER's locked reaction stays hidden (not even
//    decrypted) until a message catch-up pass that began after its first read
//    was read to its end; then a new read opens it. Own rows open at once. No
//    timeout. Live rows arriving during a resume pass follow the same gate.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/catch_up_mark.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/application/reaction_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_reaction_store.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/reaction_envelope.dart';
import 'package:sis/features/chat/domain/reaction_opener.dart';
import 'package:sis/features/chat/domain/message_store.dart' show ChangeCursor;
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';

import '../../support/fakes.dart';
import '../../support/key_directory_fakes.dart';
import '../../support/reaction_fakes.dart';
import '../../support/store_spy.dart' show eventually;
import '../../support/video_fakes.dart' show videoOverrides;
import 'data/store/store_harness.dart' show StoreHarness, at;

final class _FixedPickleKey implements PickleKeyStore {
  _FixedPickleKey(this.key);
  final List<int> key;
  @override
  Future<List<int>> loadOrCreate() async => key;
  @override
  Future<void> delete() async {}
}

/// Counts and orders decrypt calls; everything else passes through.
final class SpyEngine implements SessionEngine {
  SpyEngine(this.inner);
  final SessionEngine inner;
  final decrypts = <String>[];

  @override
  Future<bool> hasSession(String peerUserId) => inner.hasSession(peerUserId);
  @override
  Future<Result<String>> createOutbound(String p, ClaimedKeys k) =>
      inner.createOutbound(p, k);
  @override
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    required String peerIdentityKey,
    PlaintextSave? save,
    QueueTarget? queue,
  }) => inner.encrypt(
    peerUserId,
    plaintext,
    peerIdentityKey: peerIdentityKey,
    save: save,
    queue: queue,
  );
  @override
  Future<Result<String>> createInbound({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) {
    decrypts.add(ciphertext);
    return inner.createInbound(
      peerUserId: peerUserId,
      peerIdentityKey: peerIdentityKey,
      ciphertext: ciphertext,
      olmType: olmType,
      save: save,
    );
  }

  @override
  Future<Result<String>> decrypt({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) {
    decrypts.add(ciphertext);
    return inner.decrypt(
      peerUserId: peerUserId,
      peerIdentityKey: peerIdentityKey,
      ciphertext: ciphertext,
      olmType: olmType,
      save: save,
    );
  }
}

final class Phone {
  Phone._(this.userId, this.store, this.engine, this.claim, this.identity);
  final String userId;
  final DriftMessageStore store;
  final SpyEngine engine;
  final ClaimedKeys Function() claim;
  final ClaimedKeys identity;

  static Future<Phone> make(String userId) async {
    final h = await StoreHarness.create();
    final store = h.open(owner: userId, key: await h.newKey());
    addTearDown(store.close);
    final olm = OlmKeyEngine();
    final pk = List<int>.generate(32, (i) => (i * 3 + userId.length) % 256);
    final account = await olm.create();
    account.generateOneTimeKeys(5);
    final otks = account.unpublishedOneTimeKeys;
    account.markPublished();
    expect(await DriftOlmPickleStore(store).save(account.pickle(pk)), isTrue);
    final engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: _FixedPickleKey(pk),
    );
    final sig = account.sign(
      deviceStatement(userId, account.identityKey, account.signingKey),
    );
    var next = 0;
    ClaimedKeys claim() => ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: sig,
      oneTimeKey: otks[next++],
      isFallback: false,
    );
    final identity = ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: sig,
      oneTimeKey: '',
      isFallback: false,
    );
    return Phone._(userId, store, SpyEngine(engine), claim, identity);
  }
}

T ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok, got $r');
  return (r as Ok<T>).value;
}

const alice = '11111111-1111-4111-8111-111111111111';
const bob = '22222222-2222-4222-8222-222222222222';
const carol = '33333333-3333-4333-8333-333333333333';
String mid(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

class _Session extends SessionController {
  _Session(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Phone a; // the reader (alice)
  late Phone b; // the reactor (bob)
  late bool keyOnline;
  var sessionMade = false;
  final peerAsked = <String>[];

  setUp(() async {
    a = await Phone.make(alice);
    b = await Phone.make(bob);
    keyOnline = true;
    sessionMade = false;
    peerAsked.clear();
  });

  Future<LockedText> lockRaw(String plaintext) async {
    if (!sessionMade) {
      ok(await b.engine.createOutbound(alice, a.claim()));
      sessionMade = true;
    }
    return ok(
      await b.engine.encrypt(
        alice,
        plaintext,
        peerIdentityKey: a.identity.identityKey,
      ),
    );
  }

  /// bob's locked reaction row, as the server holds it.
  Future<Reaction> bobReacts(
    String messageId,
    String emoji, {
    int t = 0,
    String? envelopeMessage,
    String? envelopeUser,
  }) async {
    final l = await lockRaw(
      encodeReactionEnvelope(
        messageId: envelopeMessage ?? messageId,
        userId: envelopeUser ?? bob,
        emoji: emoji,
      ),
    );
    return Reaction(
      messageId: messageId,
      userId: bob,
      emoji: null,
      ciphertext: l.ciphertext,
      olmType: l.olmType,
      updatedAt: at(t),
    );
  }

  StoreReactionOpener opener({
    SessionEngine? engine,
    bool wired = true,
    CatchUpMark? mark,
    void Function()? onHeld,
  }) => StoreReactionOpener(
    me: () => alice,
    engine: () => wired ? (engine ?? a.engine) : null,
    store: () => DriftReactionStore(a.store),
    peerKey: (id) async {
      peerAsked.add(id);
      if (!keyOnline) {
        return const Err(NetworkFailure('off', retryable: true));
      }
      return Ok(b.identity);
    },
    mark: mark,
    onHeld: onHeld,
  );

  String? emojiOf(List<Reaction> rows, String m, String u) =>
      rows.firstWhere((r) => r.messageId == m && r.userId == u).emoji;

  test('a locked row opens to its emoji once, with ciphertext cleared; a '
      'plain row passes unchanged', () async {
    final row = await bobReacts(mid(1), '🦊');
    const plain = Reaction(messageId: 'p1', userId: carol, emoji: '👍');
    final out = await opener().open([row, plain]);
    expect(out, hasLength(2));
    expect(out[0].emoji, '🦊');
    expect(out[0].ciphertext, isNull);
    expect(out[1].emoji, '👍');
    expect(a.engine.decrypts, [row.ciphertext]);
  });

  test('opened once: a second read, and a new opener (app restart), read the '
      'saved copy without decrypting again', () async {
    final row = await bobReacts(mid(1), '🦊');
    final o = opener();
    expect(emojiOf(await o.open([row]), mid(1), bob), '🦊');
    expect(emojiOf(await o.open([row]), mid(1), bob), '🦊');
    expect(emojiOf(await opener().open([row]), mid(1), bob), '🦊');
    expect(a.engine.decrypts, hasLength(1));
  });

  test('a changed reaction (new ciphertext for the same message and user) '
      'opens to the new emoji', () async {
    final o = opener();
    expect(
      emojiOf(await o.open([await bobReacts(mid(1), '🦊')]), mid(1), bob),
      '🦊',
    );
    final changed = await bobReacts(mid(1), '🐝', t: 1);
    expect(emojiOf(await o.open([changed]), mid(1), bob), '🐝');
  });

  test('E1: an envelope for another message is hidden, never shown', () async {
    final row = await bobReacts(mid(2), '🦊', envelopeMessage: mid(1));
    expect(emojiOf(await opener().open([row]), mid(2), bob), isNull);
  });

  test('E1: an envelope of another reactor (a replay) is hidden', () async {
    final row = await bobReacts(mid(1), '🦊', envelopeUser: carol);
    expect(emojiOf(await opener().open([row]), mid(1), bob), isNull);
  });

  test('E1: a MESSAGE envelope in a reaction row is hidden', () async {
    final l = await lockRaw(encodeEnvelope(id: mid(1), text: '🦊'));
    final row = Reaction(
      messageId: mid(1),
      userId: bob,
      emoji: null,
      ciphertext: l.ciphertext,
      olmType: l.olmType,
      updatedAt: at(0),
    );
    expect(emojiOf(await opener().open([row]), mid(1), bob), isNull);
  });

  test('garbage ciphertext is hidden and nothing throws', () async {
    await lockRaw('warm-up'); // a session exists, so the bytes are the issue
    final row = Reaction(
      messageId: mid(1),
      userId: bob,
      emoji: null,
      ciphertext: base64.encode(List.filled(80, 7)),
      olmType: 1,
      updatedAt: at(0),
    );
    expect(emojiOf(await opener().open([row]), mid(1), bob), isNull);
  });

  test('no session engine (not wired): a locked row is hidden', () async {
    final row = await bobReacts(mid(1), '🦊');
    expect(
      emojiOf(await opener(wired: false).open([row]), mid(1), bob),
      isNull,
    );
  });

  test('the key lookup fails: hidden and NOT consumed; it opens on a later '
      'read', () async {
    final row = await bobReacts(mid(1), '🦊');
    keyOnline = false;
    final o = opener();
    expect(emojiOf(await o.open([row]), mid(1), bob), isNull);
    expect(a.engine.decrypts, isEmpty);
    keyOnline = true;
    expect(emojiOf(await o.open([row]), mid(1), bob), '🦊');
  });

  test('own rows are never decrypted: hidden without rememberOwn, shown from '
      'it', () async {
    const ct = 'T1dOX1JFQUNUSU9OX0JZVEVT';
    const own = Reaction(
      messageId: 'm-own',
      userId: alice,
      emoji: null,
      ciphertext: ct,
      olmType: 1,
    );
    final o = opener();
    expect(emojiOf(await o.open([own]), 'm-own', alice), isNull);
    await o.rememberOwn('m-own', alice, ct, '🐙');
    expect(emojiOf(await o.open([own]), 'm-own', alice), '🐙');
    expect(a.engine.decrypts, isEmpty);
    expect(peerAsked, isNot(contains(alice)));
    expect(await o.ownUsage(alice), {'🐙': 1});
  });

  test('the saved copy is keyed by the ciphertext hash: another ciphertext '
      'does not show it', () async {
    final o = opener();
    await o.rememberOwn('m-own', alice, 'QUFB', '🐙');
    const other = Reaction(
      messageId: 'm-own',
      userId: alice,
      emoji: null,
      ciphertext: 'QkJC',
      olmType: 1,
    );
    expect(emojiOf(await o.open([other]), 'm-own', alice), isNull);
    expect(
      await DriftReactionStore(
        a.store,
      ).emojiOf('m-own', alice, sha256.convert(utf8.encode('QUFB')).toString()),
      '🐙',
      reason: 'sealed = sha256 hex of the ciphertext',
    );
  });

  test(
    'locked rows open oldest first, whatever order they arrive in',
    () async {
      final r1 = await bobReacts(mid(1), '🦊', t: 1);
      final r2 = await bobReacts(mid(2), '🐝', t: 2);
      final r3 = await bobReacts(mid(3), '🐙', t: 3);
      final out = await opener().open([r2, r3, r1]);
      expect(
        [for (final r in out) r.emoji],
        ['🐝', '🐙', '🦊'],
        reason: 'the order of the rows is kept',
      );
      expect(a.engine.decrypts, [r1.ciphertext, r2.ciphertext, r3.ciphertext]);
    },
  );

  test('F3: every locked reaction has the same ciphertext length', () async {
    await lockRaw('warm-up');
    final lengths = <int>{};
    for (final e in [
      'a',
      '👍',
      '👍🏽',
      '👨‍👩‍👧',
      '🏴󠁧󠁢󠁳󠁣󠁴󠁿',
      '😀' * 16,
    ]) {
      lengths.add((await bobReacts(mid(1), e)).ciphertext!.length);
    }
    expect(lengths, hasLength(1), reason: 'lengths: $lengths');
  });

  test('nothing logs the emoji, the plaintext or the ciphertext', () async {
    final lines = <String>[];
    final saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    final rows = <Reaction>[];
    try {
      await runZoned(
        () async {
          rows.add(await bobReacts(mid(1), '🦄'));
          rows.add(await bobReacts(mid(2), '🦄', envelopeUser: carol));
          rows.add(
            Reaction(
              messageId: mid(3),
              userId: bob,
              emoji: null,
              ciphertext: base64.encode(List.filled(80, 7)),
              olmType: 1,
            ),
          );
          final o = opener();
          await o.open(rows);
          await o.rememberOwn('m-own', alice, 'QUFB', '🦄');
          keyOnline = false;
          await o.open([await bobReacts(mid(4), '🦄')]);
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => lines.add(line),
        ),
      );
    } finally {
      debugPrint = saved;
    }
    for (final l in lines) {
      expect(l, isNot(contains('🦄')));
      for (final r in rows) {
        expect(l, isNot(contains(r.ciphertext!)));
      }
    }
  });

  group('R1: a peer\'s locked reaction waits for a full catch-up pass', () {
    late CatchUpMark mark;
    late int held;
    setUp(() {
      mark = CatchUpMark();
      held = 0;
    });
    StoreReactionOpener gated() => opener(mark: mark, onHeld: () => held++);

    test('hidden (not decrypted) on the first read; a pass that began after '
        'it opens it on the next read', () async {
      final row = await bobReacts(mid(1), '🦊');
      final o = gated();
      expect(emojiOf(await o.open([row]), mid(1), bob), isNull);
      expect(a.engine.decrypts, isEmpty, reason: 'decrypted before the pass');
      expect(mark.takeHolding(), isTrue, reason: 'the hold is announced');
      expect(held, greaterThan(0), reason: 'a catch-up is asked for');
      mark.passDone(mark.stamp());
      expect(emojiOf(await o.open([row]), mid(1), bob), '🦊');
      expect(a.engine.decrypts, [row.ciphertext]);
    });

    test('a pass that began BEFORE the first read does not count', () async {
      final row = await bobReacts(mid(1), '🦊');
      final o = gated();
      final early = mark.stamp();
      expect(emojiOf(await o.open([row]), mid(1), bob), isNull);
      mark.passDone(early);
      expect(emojiOf(await o.open([row]), mid(1), bob), isNull);
      expect(a.engine.decrypts, isEmpty);
      mark.passDone(mark.stamp());
      expect(emojiOf(await o.open([row]), mid(1), bob), '🦊');
    });

    test('each row waits for a pass after ITS first read', () async {
      final r1 = await bobReacts(mid(1), '🦊', t: 1);
      final r2 = await bobReacts(mid(2), '🐝', t: 2);
      final o = gated();
      await o.open([r1]);
      mark.passDone(mark.stamp());
      final out = await o.open([r1, r2]);
      expect(emojiOf(out, mid(1), bob), '🦊');
      expect(
        emojiOf(out, mid(2), bob),
        isNull,
        reason: 'r2 was first read now',
      );
      mark.passDone(mark.stamp());
      expect(emojiOf(await o.open([r2]), mid(2), bob), '🐝');
    });

    test('no timeout: 6 s without a pass never opens it', () async {
      final row = await bobReacts(mid(1), '🦊');
      final o = gated();
      expect(emojiOf(await o.open([row]), mid(1), bob), isNull);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(emojiOf(await o.open([row]), mid(1), bob), isNull);
      expect(a.engine.decrypts, isEmpty);
    });

    test('own reactions and plain rows show at once, without a pass', () async {
      const own = Reaction(
        messageId: 'm-own',
        userId: alice,
        emoji: null,
        ciphertext: 'T1dO',
        olmType: 1,
      );
      const plain = Reaction(messageId: 'p1', userId: carol, emoji: '👍');
      final o = gated();
      await o.rememberOwn('m-own', alice, 'T1dO', '🐙');
      final out = await o.open([own, plain]);
      expect(emojiOf(out, 'm-own', alice), '🐙');
      expect(emojiOf(out, 'p1', carol), '👍');
    });
  });

  /// The production wiring around [a]'s phone: the real opener provider (its
  /// queue, CatchUpMark and store sync), a server whose change feed is [feed].
  ProviderContainer wired(
    ChatFake feed, {
    ReactionFake Function(ReactionOpener Function() opener)? reactions,
  }) {
    final log = <String>[];
    final dir = FakeKeyDirectory(log)..identityAnswer = Ok(b.identity);
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(feed),
        sessionControllerProvider.overrideWith(
          () => _Session(const Member(userId: alice, displayName: 'Alice')),
        ),
        sessionEngineProvider.overrideWithValue(a.engine),
        messageStoreProvider.overrideWithValue(a.store),
        reactionStoreProvider.overrideWithValue(DriftReactionStore(a.store)),
        keyDirectoryProvider.overrideWithValue(dir),
        keyEngineProvider.overrideWithValue(FakeEngine(log)),
        ...videoOverrides(),
        if (reactions != null)
          reactionRepositoryProvider.overrideWith(
            (ref) => reactions(() => ref.read(reactionOpenerProvider)),
          ),
      ],
    );
    return c;
  }

  for (final withReaction in [false, true]) {
    test(
      withReaction
          ? 'F1 + R1: > 40 locked messages, then a locked reaction, opened at '
                'once as production wires both openers: every message opens; '
                'the reaction is hidden until the catch-up pass it asked for '
                'is done, then opens'
          : 'F1 control: the same 80 messages without the reaction all open',
      () async {
        final messages = <Message>[];
        for (var i = 0; i < 80; i++) {
          final l = await lockRaw(
            encodeEnvelope(id: mid(100 + i), text: 'text $i'),
          );
          messages.add(
            Message(
              id: mid(100 + i),
              conversationId: 'c1',
              senderId: bob,
              body: lockedBodyPlaceholder,
              createdAt: at(i),
              ciphertext: l.ciphertext,
              olmType: l.olmType,
            ),
          );
        }
        final reaction = await bobReacts(mid(100), '🦊', t: 90);

        final c = wired(ChatFake());
        await c.read(sessionControllerProvider.future);
        c.listen(currentUserIdProvider, (_, _) {});
        final pass = c.read(catchUpMarkProvider).passes.first;

        final opened = await Future.wait([
          c.read(messageOpenerProvider).open(messages),
          if (withReaction) c.read(reactionOpenerProvider).open([reaction]),
        ]);
        final texts = [for (final m in opened[0] as List<Message>) m.body];
        final lost = [
          for (var i = 0; i < texts.length; i++)
            if (texts[i] != 'text $i') i,
        ];
        expect(lost, isEmpty, reason: 'messages that did not open: $lost');
        if (withReaction) {
          expect(
            (opened[1] as List<Reaction>).single.emoji,
            isNull,
            reason: 'R1: no catch-up pass has run since it was read',
          );
          await pass.timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('the hold never asked for a catch-up pass'),
          );
          final again = await c.read(reactionOpenerProvider).open([reaction]);
          expect(again.single.emoji, '🦊');
        }
        // 80 real Olm opens: CPU-bound, past the default 30 s on a busy machine.
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test('R1 live on resume: a locked reaction arriving while the resume pass '
      'runs stays hidden after that pass, and shows after the next one, with '
      'no user action', () async {
    final feed = _GatedFeed();
    late _OpeningReactions server;
    final c = wired(feed, reactions: (o) => server = _OpeningReactions(o));
    await c.read(sessionControllerProvider.future);
    c.listen(currentUserIdProvider, (_, _) {});
    await a.store.saveCursor(ChangeCursor(at(0), 'seed'));
    c.listen(messagesProvider, (_, _) {});
    c.listen(reactionsProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(reactionsProvider.future);
    String? shown() => [
      for (final r in c.read(reactionsProvider).value?[mid(1)] ?? <Reaction>[])
        if (r.userId == bob) r.emoji,
    ].firstOrNull;

    // resume: the catch-up pass starts and is still reading the feed
    final first = Completer<void>();
    final second = Completer<void>();
    feed.gates.addAll([first, second]);
    final resume = c.read(storeSyncProvider).run();
    await eventually(() => feed.reads >= 1, reason: 'the resume pass reads');

    final row = await bobReacts(mid(1), '🦊');
    server.server['c1'] = [row];
    server.emit('c1', row);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(shown(), isNull, reason: 'arrived during the pass');
    expect(a.engine.decrypts, isEmpty);

    // The resume pass ends (a run() asked meanwhile may restart it; either
    // way it began before the row was read). The next pass is held.
    first.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      shown(),
      isNull,
      reason: 'the resume pass began before the row was read',
    );
    expect(a.engine.decrypts, isEmpty);

    second.complete();
    await eventually(
      () => shown() == '🦊',
      timeout: const Duration(seconds: 20),
      reason: 'never shown after a later full pass',
    );
    await resume.timeout(const Duration(seconds: 20));
  });
}

/// A change feed that is always empty; the nth read waits for gates[n-1].
class _GatedFeed extends ChatFake {
  final gates = <Completer<void>>[];
  int reads = 0;

  @override
  Future<Result<ChangePage>> changesSince(
    ChangeCursor cursor, {
    int limit = 500,
  }) async {
    final n = reads++;
    await Future<void>.delayed(Duration.zero);
    if (n < gates.length) await gates[n].future;
    return const Ok(ChangePage(<Message>[], null));
  }
}

/// The server rows of [ReactionFake], handed out OPENED through the opener
/// main.dart gives the real repository (loads and the live feed alike).
class _OpeningReactions extends ReactionFake {
  _OpeningReactions(this.opener) : super(me: alice);
  final ReactionOpener Function() opener;

  @override
  Future<Result<List<Reaction>>> reactions(String conversationId) async {
    final r = await super.reactions(conversationId);
    return switch (r) {
      Ok(:final value) => Ok(await opener().open(value)),
      Err() => r,
    };
  }

  @override
  Future<Result<Stream<Reaction>>> reactionUpdates(
    String conversationId,
  ) async {
    final r = await super.reactionUpdates(conversationId);
    return switch (r) {
      Ok(:final value) => Ok(
        value.asyncMap((x) async => (await opener().open([x])).single),
      ),
      Err() => r,
    };
  }
}
