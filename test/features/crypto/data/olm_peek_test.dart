// peekDecrypt with REAL Olm (OlmKeyEngine over the compiled vodozemac library)
// and hand-built PeekRows. Written from the peek contract (QA interface of
// Private Chats 4b Group G), never from the implementation: a peek returns the
// text of a message locked for this phone, or null, and never saves anything.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/olm_peek.dart';
import 'package:sis/features/crypto/data/olm_peek_store.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

final pk = List<int>.generate(32, (i) => (i * 11 + 3) % 256);
final otherPk = List<int>.generate(32, (i) => (i * 5 + 1) % 256);

List<int> env(String id, String text) =>
    utf8.encode(encodeEnvelope(id: id, text: text));

String b64(OlmCipher c) => base64Encode(c.body);

/// Every fixture of one exchange alice -> bob, captured at the moment the
/// store on Bob's phone would hold it.
late OlmKeyEngine olm;
late String aliceIdentity;

/// Bob's account before he opened Alice's first pre-key message (OTK 0 unused).
late String bobAccountBefore;

/// Bob's account after that (OTK 0 consumed, OTK 1 still there).
late String bobAccountAfter;

/// Bob's session right after the inbound, and after his reply went out.
late String bobSessionFresh;
late String bobSessionNow;
late String bobSessionId;

/// m0: first pre-key; m0b: second pre-key on the same session (no reply yet);
/// m1: normal message after Bob's reply; m2: pre-key on a NEW session (OTK 1).
late OlmCipher c0, c0b, c1, c2;

PeekSession session(String pickle, {String peer = 'alice', String? id}) =>
    PeekSession(
      sessionId: id ?? bobSessionId,
      peerUserId: peer,
      peerIdentityKey: aliceIdentity,
      pickle: pickle,
    );

PeekRows rows({
  String? peer = 'alice',
  String? account,
  bool noAccount = false,
  List<PeekSession>? sessions,
}) => PeekRows(
  ownerId: 'bob',
  peerUserId: peer,
  storedBody: '🔒 Encrypted message',
  account: noAccount ? null : (account ?? bobAccountAfter),
  sessions: sessions ?? [session(bobSessionNow)],
);

Future<String?> peek(
  PeekRows r, {
  required String id,
  required OlmCipher c,
  String? ciphertext,
  int? type,
  List<int>? key,
}) => peekDecrypt(
  rows: r,
  pickleKey: key ?? pk,
  messageId: id,
  ciphertext: ciphertext ?? b64(c),
  olmType: type ?? c.type,
  engine: olm,
);

void main() {
  setUpAll(() async {
    olm = OlmKeyEngine();
    Future<SessionAccount> account() async {
      final a = await olm.create();
      a.generateOneTimeKeys(3);
      return olm.restoreSessionAccount(a.pickle(pk), pk);
    }

    final alice = await account();
    final bob = await account();
    aliceIdentity = alice.identityKey;
    final otks = bob.unpublishedOneTimeKeys;

    final out = alice.createOutbound(bob.identityKey, otks[0]);
    c0 = out.encrypt(env('m0', 'first'));
    c0b = out.encrypt(env('m0b', 'second pre-key'));
    bobAccountBefore = bob.pickle(pk);

    final inbound = bob.createInbound(alice.identityKey, c0);
    expect(utf8.decode(inbound.plaintext), contains('first'));
    bobAccountAfter = bob.pickle(pk);
    bobSessionId = inbound.session.sessionId;
    bobSessionFresh = inbound.session.pickle(pk);

    out.decrypt(inbound.session.encrypt(env('r1', 'reply')));
    c1 = out.encrypt(env('m1', 'hello normal'));
    bobSessionNow = inbound.session.pickle(pk);

    c2 = alice
        .createOutbound(bob.identityKey, otks[1])
        .encrypt(env('m2', 'new session'));

    expect([c0.type, c0b.type, c1.type, c2.type], [0, 0, 1, 0]);
  });

  group('success', () {
    test('a normal message (type 1) returns its text', () async {
      expect(await peek(rows(), id: 'm1', c: c1), 'hello normal');
    });

    test('type 1 tries every session of the peer, newest first', () async {
      // A session that cannot open m1 (unreadable pickle) comes first.
      final broken = '${bobSessionNow.substring(0, 10)}AAAA';
      final r = rows(
        sessions: [
          session(broken, id: 'newer-broken'),
          session(bobSessionNow),
        ],
      );
      expect(await peek(r, id: 'm1', c: c1), 'hello normal');
    });

    test(
      'a pre-key message on a stored session id uses that session',
      () async {
        final r = rows(sessions: [session(bobSessionFresh)]);
        expect(await peek(r, id: 'm0b', c: c0b), 'second pre-key');
      },
    );

    test(
      'a pre-key message on a NEW session opens an inbound session '
      'on the copy only (peek twice, both succeed, rows unchanged)',
      () async {
        final sessions = [session(bobSessionNow)];
        final r = rows(sessions: sessions);
        expect(await peek(r, id: 'm2', c: c2), 'new session');
        // The one-time key is still in the account: nothing was consumed.
        expect(await peek(r, id: 'm2', c: c2), 'new session');
        expect(r.account, bobAccountAfter);
        expect(r.sessions, hasLength(1));
        expect(r.sessions.single.pickle, bobSessionNow);
      },
    );

    test(
      'peeking a normal message twice works (session not advanced)',
      () async {
        final r = rows();
        expect(await peek(r, id: 'm1', c: c1), 'hello normal');
        expect(await peek(r, id: 'm1', c: c1), 'hello normal');
        expect(r.sessions.single.pickle, bobSessionNow);
      },
    );
  });

  group('null (stay locked)', () {
    test(
      'wrong peer: sessions belong to alice, the chat peer is carol',
      () async {
        final r = rows(
          peer: 'carol',
          sessions: [session(bobSessionNow, peer: 'alice')],
        );
        expect(await peek(r, id: 'm1', c: c1), isNull);
      },
    );

    test('wrong peer on the pre-key stored-session path', () async {
      final r = rows(
        peer: 'carol',
        sessions: [session(bobSessionFresh, peer: 'alice')],
      );
      expect(await peek(r, id: 'm0b', c: c0b), isNull);
    });

    test('unknown peer (null)', () async {
      expect(await peek(rows(peer: null), id: 'm1', c: c1), isNull);
    });

    test('envelope id differs from the message id', () async {
      expect(await peek(rows(), id: 'm-other', c: c1), isNull);
    });

    test('envelope id differs on the pre-key inbound path', () async {
      expect(await peek(rows(), id: 'm-other', c: c2), isNull);
    });

    test('garbage base64', () async {
      expect(
        await peek(rows(), id: 'm1', c: c1, ciphertext: '!!not base64!!'),
        isNull,
      );
    });

    test('olmType 2', () async {
      expect(await peek(rows(), id: 'm1', c: c1, type: 2), isNull);
    });

    test('olmType -1', () async {
      expect(await peek(rows(), id: 'm1', c: c1, type: -1), isNull);
    });

    test('type 1 with no sessions', () async {
      expect(
        await peek(
          rows(sessions: []),
          id: 'm1',
          c: c1,
        ),
        isNull,
      );
    });

    test('type 0 with no sessions (first-ever message stays locked)', () async {
      expect(
        await peek(
          rows(account: bobAccountBefore, sessions: []),
          id: 'm0',
          c: c0,
        ),
        isNull,
      );
    });

    test('type 0 on a new session with no account', () async {
      expect(await peek(rows(noAccount: true), id: 'm2', c: c2), isNull);
    });

    test('corrupt session pickle', () async {
      final bad =
          '${bobSessionNow.substring(0, bobSessionNow.length - 8)}AAAAAAAA';
      expect(
        await peek(
          rows(sessions: [session(bad)]),
          id: 'm1',
          c: c1,
        ),
        isNull,
      );
    });

    test('corrupt account pickle on the pre-key inbound path', () async {
      final bad =
          '${bobAccountAfter.substring(0, bobAccountAfter.length - 8)}AAAAAAAA';
      expect(
        await peek(
          rows(account: bad),
          id: 'm2',
          c: c2,
        ),
        isNull,
      );
    });

    test('wrong pickle key', () async {
      expect(await peek(rows(), id: 'm1', c: c1, key: otherPk), isNull);
    });

    test('tampered ciphertext', () async {
      final bytes = List<int>.of(c1.body);
      bytes[bytes.length - 1] ^= 1;
      expect(
        await peek(rows(), id: 'm1', c: c1, ciphertext: base64Encode(bytes)),
        isNull,
      );
    });
  });
}
