// peekDecrypt with the sender key of a pre-key push (sk = senderKey,
// si = senderId), over REAL Olm (vodozemac) and hand-built PeekRows. Written
// from the contract (t_9071b06f08 fix C, "Contract for qa-lead"), never from
// the implementation:
// - olmType 0, no stored session of the peer: a well-formed sk/si whose si is
//   the chat's peer (or the chat has no known peer) opens the message on an
//   in-memory copy of the account; nothing is saved, the one-time key stays.
// - a stored session of the peer wins: its key is used, sk is ignored.
// - snapshot peer != si => null 'no_peer'.
// - sk or si malformed, or sk stored for another peer (keyPeers) => null
//   'decrypt_fail'. sk/si absent, or no account => 'no_session'.
// - olmType 1 never uses sk/si. onFail at most once, never on success.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/olm_peek.dart';
import 'package:sis/features/crypto/data/olm_peek_store.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

const aliceId = '0000a11c-0000-4000-8000-000000000001';
const bobId = '0000a11c-0000-4000-8000-000000000002';
const carolId = '0000a11c-0000-4000-8000-000000000003';
final pk = List<int>.generate(32, (i) => (i * 13 + 7) % 256);

List<int> env(String id, String text) =>
    utf8.encode(encodeEnvelope(id: id, text: text));

/// The real engine, recording what the peek asks of it.
final class SpyEngine implements SessionKeyEngine {
  SpyEngine(this.real);
  final OlmKeyEngine real;
  int calls = 0;
  final inboundKeys = <String>[];
  int pickles = 0;

  @override
  Future<SessionAccount> restoreSessionAccount(String p, List<int> k) async {
    calls++;
    return SpyAccount(await real.restoreSessionAccount(p, k), this);
  }

  @override
  Future<KeySession> restoreSession(String p, List<int> k) {
    calls++;
    return real.restoreSession(p, k);
  }

  @override
  Future<String> preKeySessionId(OlmCipher m) {
    calls++;
    return real.preKeySessionId(m);
  }
}

final class SpyAccount implements SessionAccount {
  SpyAccount(this.a, this.spy);
  final SessionAccount a;
  final SpyEngine spy;
  @override
  InboundSession createInbound(String theirIdentityKey, OlmCipher message) {
    spy.inboundKeys.add(theirIdentityKey);
    return a.createInbound(theirIdentityKey, message);
  }

  @override
  String pickle(List<int> key) {
    spy.pickles++;
    return a.pickle(key);
  }

  @override
  KeySession createOutbound(String k, String otk) => a.createOutbound(k, otk);
  @override
  String get identityKey => a.identityKey;
  @override
  String get signingKey => a.signingKey;
  @override
  int get maxOneTimeKeys => a.maxOneTimeKeys;
  @override
  int get storedOneTimeKeyCount => a.storedOneTimeKeyCount;
  @override
  void generateOneTimeKeys(int count) => a.generateOneTimeKeys(count);
  @override
  void generateFallbackKey() => a.generateFallbackKey();
  @override
  List<String> get unpublishedOneTimeKeys => a.unpublishedOneTimeKeys;
  @override
  String? get unpublishedFallbackKey => a.unpublishedFallbackKey;
  @override
  void markPublished() => a.markPublished();
  @override
  String sign(String message) => a.sign(message);
}

late OlmKeyEngine olm;
late String aliceKey, alice2Key, carolKey;

/// Bob before any message (both one-time keys), and after opening c0.
late String bobBefore, bobAfter;

/// Bob's stored session with alice (her key aliceKey), after c0.
late PeekSession aliceSession;

/// c0: alice's first pre-key message (OTK 0). cNew: a pre-key from alice's
/// NEW phone (key alice2Key, OTK 1). c1: a normal message on c0's session.
late OlmCipher c0, cNew, c1;

PeekRows rows({
  String? peer = aliceId,
  String? account,
  bool noAccount = false,
  List<PeekSession> sessions = const [],
  List<String> keyPeers = const [],
}) => PeekRows(
  ownerId: bobId,
  peerUserId: peer,
  storedBody: '🔒 Encrypted message',
  account: noAccount ? null : (account ?? bobBefore),
  sessions: sessions,
  keyPeers: keyPeers,
);

final reasons = <String>[];
late SpyEngine spy;

Future<String?> peek(
  PeekRows r, {
  String id = 'm0',
  OlmCipher? c,
  String? sk,
  String? si,
}) {
  final m = c ?? c0;
  return peekDecrypt(
    rows: r,
    pickleKey: pk,
    messageId: id,
    ciphertext: base64Encode(m.body),
    olmType: m.type,
    engine: spy,
    onFail: reasons.add,
    senderKey: sk,
    senderId: si,
  );
}

void main() {
  setUpAll(() async {
    olm = OlmKeyEngine();
    Future<SessionAccount> account() async {
      final a = await olm.create();
      a.generateOneTimeKeys(2);
      return olm.restoreSessionAccount(a.pickle(pk), pk);
    }

    final alice = await account();
    final alice2 = await account();
    final carol = await account();
    final bob = await account();
    aliceKey = alice.identityKey;
    alice2Key = alice2.identityKey;
    carolKey = carol.identityKey;
    final otks = bob.unpublishedOneTimeKeys;
    bobBefore = bob.pickle(pk);

    final out = alice.createOutbound(bob.identityKey, otks[0]);
    c0 = out.encrypt(env('m0', 'first words'));
    cNew = alice2
        .createOutbound(bob.identityKey, otks[1])
        .encrypt(env('mN', 'from the new phone'));

    final inbound = bob.createInbound(aliceKey, c0);
    bobAfter = bob.pickle(pk);
    out.decrypt(inbound.session.encrypt(env('r1', 'reply')));
    c1 = out.encrypt(env('m1', 'normal'));
    aliceSession = PeekSession(
      sessionId: inbound.session.sessionId,
      peerUserId: aliceId,
      peerIdentityKey: aliceKey,
      pickle: inbound.session.pickle(pk),
    );
    expect([c0.type, cNew.type, c1.type], [0, 0, 1]);
  });

  setUp(() {
    reasons.clear();
    spy = SpyEngine(olm);
  });

  group('the first message opens with sk/si', () {
    test('no stored session, si = the chat peer: the text', () async {
      expect(await peek(rows(), sk: aliceKey, si: aliceId), 'first words');
      expect(reasons, isEmpty, reason: 'onFail is never called on success');
      expect(spy.inboundKeys, [aliceKey]);
    });

    test('the chat has no known peer: si is the peer for this call', () async {
      expect(
        await peek(rows(peer: null), sk: aliceKey, si: aliceId),
        'first words',
      );
      expect(reasons, isEmpty);
    });

    test('nothing is saved: twice the same text, the account is never '
        'pickled, and the real app can still open c0 afterwards', () async {
      final r = rows();
      expect(await peek(r, sk: aliceKey, si: aliceId), 'first words');
      expect(await peek(r, sk: aliceKey, si: aliceId), 'first words');
      expect(spy.pickles, 0, reason: 'the account copy was pickled');
      expect(r.account, bobBefore);
      final bob = await olm.restoreSessionAccount(bobBefore, pk);
      final opened = bob.createInbound(aliceKey, c0);
      expect(utf8.decode(opened.plaintext), contains('first words'));
    });
  });

  group('stays locked', () {
    test("wrong sk (carol's key) => null, 'decrypt_fail'", () async {
      expect(await peek(rows(), sk: carolKey, si: aliceId), isNull);
      expect(reasons, ['decrypt_fail']);
    });

    test("sk and si absent => null, 'no_session' (old server)", () async {
      expect(await peek(rows()), isNull);
      expect(reasons, ['no_session']);
    });

    test("no account => null, 'no_session'", () async {
      expect(
        await peek(rows(noAccount: true), sk: aliceKey, si: aliceId),
        isNull,
      );
      expect(reasons, ['no_session']);
    });

    test("snapshot peer carol, si alice => null 'no_peer', no inbound "
        'session is tried', () async {
      expect(
        await peek(
          rows(peer: carolId),
          sk: aliceKey,
          si: aliceId,
        ),
        isNull,
      );
      expect(reasons, ['no_peer']);
      expect(spy.inboundKeys, isEmpty);
    });

    test('a stored session of the peer wins: its key is used and sk is '
        'ignored', () async {
      // Alice's new phone (key alice2Key) sends a pre-key; Bob still holds
      // her old session (aliceKey).
      final r = rows(account: bobAfter, sessions: [aliceSession]);
      expect(
        await peek(r, id: 'mN', c: cNew, sk: alice2Key, si: aliceId),
        isNull,
      );
      expect(spy.inboundKeys, isNot(contains(alice2Key)));
      expect(reasons, hasLength(1));
      // Control: without the stored session the same push opens.
      reasons.clear();
      expect(
        await peek(
          rows(account: bobAfter),
          id: 'mN',
          c: cNew,
          sk: alice2Key,
          si: aliceId,
        ),
        'from the new phone',
      );
    });

    test("sk stored for another peer (keyPeers carol) => null "
        "'decrypt_fail'", () async {
      expect(
        await peek(
          rows(keyPeers: [carolId]),
          sk: aliceKey,
          si: aliceId,
        ),
        isNull,
      );
      expect(reasons, ['decrypt_fail']);
      expect(spy.inboundKeys, isEmpty);
    });

    test('keyPeers holding only si itself is not a refusal', () async {
      expect(
        await peek(
          rows(keyPeers: [aliceId]),
          sk: aliceKey,
          si: aliceId,
        ),
        'first words',
      );
    });

    for (final (label, sk, si) in [
      ('sk 42 chars', 'A' * 42, aliceId),
      ('sk 44 chars', 'A' * 44, aliceId),
      ('sk with a space', '${'A' * 42} ', aliceId),
      ('sk url-safe alphabet', '${'A' * 42}-', aliceId),
      ('si not a uuid', null, 'alice'),
      ('si uuid without dashes', null, aliceId.replaceAll('-', '')),
      ('si empty', null, ''),
      // t_5d6bdca09e: only the lowercase form a uuid column prints.
      ('si uppercase uuid', null, aliceId.toUpperCase()),
    ]) {
      test("malformed: $label => null 'decrypt_fail'", () async {
        // A bad si is tried with no snapshot peer, so it cannot be a no_peer.
        final r = sk == null ? rows(peer: null) : rows();
        expect(await peek(r, sk: sk ?? aliceKey, si: si), isNull);
        expect(reasons, ['decrypt_fail']);
        expect(spy.inboundKeys, isEmpty);
      });
    }

    test('the envelope id must still match the message id', () async {
      expect(
        await peek(rows(), id: 'm-other', sk: aliceKey, si: aliceId),
        isNull,
      );
      expect(reasons, hasLength(1));
    });

    test('olmType 1 never uses sk/si (no sessions => no_session)', () async {
      expect(
        await peek(rows(), id: 'm1', c: c1, sk: aliceKey, si: aliceId),
        isNull,
      );
      expect(reasons, ['no_session']);
      expect(spy.inboundKeys, isEmpty);
    });

    test("olmType 1 with no known chat peer: si does not become the peer "
        "(null 'no_peer')", () async {
      final r = rows(peer: null, account: bobAfter, sessions: [aliceSession]);
      expect(await peek(r, id: 'm1', c: c1, sk: aliceKey, si: aliceId), isNull);
      expect(reasons, ['no_peer']);
    });
  });
}
