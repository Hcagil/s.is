// peekDecrypt's onStoredKey (slice 2 W1, t_428ad7c883; rule B1 t_a7085eeee6)
// over REAL Olm: it fires when the text was opened and passed every check -- a
// session or peer key already STORED on the phone, or the push's own sender
// key (sk) after the shape/peer/key checks -- never on failure.
// Drafted by test_writer from the contract; reviewed and mutation-checked by qa.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/olm_peek.dart';
import 'package:sis/features/crypto/data/olm_peek_store.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

const aliceId = '0000a11c-0000-4000-8000-000000000001';
const bobId = '0000a11c-0000-4000-8000-000000000002';

late OlmKeyEngine olm;
late List<int> pk;
late String aliceKey;
late String bobBefore;
late String bobAfter;
late OlmCipher c0;
late OlmCipher c0b;
late OlmCipher cNew2;
late OlmCipher c1;
late PeekSession aliceSession;
late PeekSession aliceSessionFresh;

List<int> env(String id, String text) =>
    utf8.encode(encodeEnvelope(id: id, text: text));

PeekRows rows({
  String? peer = aliceId,
  String? account,
  List<PeekSession> sessions = const [],
}) => PeekRows(
  ownerId: bobId,
  peerUserId: peer,
  storedBody: '🔒 Encrypted message',
  account: account ?? bobBefore,
  sessions: sessions,
  keyPeers: const [],
);

void main() {
  setUpAll(() async {
    olm = OlmKeyEngine();
    pk = List<int>.generate(32, (i) => (i * 13 + 7) % 256);

    Future<SessionAccount> account() async {
      final a = await olm.create();
      a.generateOneTimeKeys(2);
      return olm.restoreSessionAccount(a.pickle(pk), pk);
    }

    final alice = await account();
    final bob = await account();
    aliceKey = alice.identityKey;
    final otks = bob.unpublishedOneTimeKeys;
    bobBefore = bob.pickle(pk);
    final out = alice.createOutbound(bob.identityKey, otks[0]);
    c0 = out.encrypt(env('m0', 'first words'));
    c0b = out.encrypt(env('m0b', 'second'));
    cNew2 = alice
        .createOutbound(bob.identityKey, otks[1])
        .encrypt(env('mX', 'new session'));
    final inbound = bob.createInbound(aliceKey, c0);
    bobAfter = bob.pickle(pk);
    aliceSessionFresh = PeekSession(
      sessionId: inbound.session.sessionId,
      peerUserId: aliceId,
      peerIdentityKey: aliceKey,
      pickle: inbound.session.pickle(pk),
    );
    out.decrypt(inbound.session.encrypt(env('r1', 'reply')));
    c1 = out.encrypt(env('m1', 'normal'));
    aliceSession = PeekSession(
      sessionId: inbound.session.sessionId,
      peerUserId: aliceId,
      peerIdentityKey: aliceKey,
      pickle: inbound.session.pickle(pk),
    );
    expect([c0.type, c0b.type, cNew2.type, c1.type], [0, 0, 0, 1]);
  });

  test('type 1 with stored session', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobAfter, sessions: [aliceSession]),
      pickleKey: pk,
      messageId: 'm1',
      ciphertext: base64Encode(c1.body),
      olmType: c1.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(result, 'normal');
    expect(fired, 1);
  });

  test('a replay of c0 after the app opened it (its key is used up): null, '
      'not fired', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobAfter, sessions: [aliceSession]),
      pickleKey: pk,
      messageId: 'm0',
      ciphertext: base64Encode(c0.body),
      olmType: c0.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(result, isNull);
    expect(fired, 0);
  });

  test('type 0 second pre-key on same outbound session', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobAfter, sessions: [aliceSessionFresh]),
      pickleKey: pk,
      messageId: 'm0b',
      ciphertext: base64Encode(c0b.body),
      olmType: c0b.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(result, 'second');
    expect(fired, 1);
  });

  test('type 0 new session with stored peer key', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobAfter, sessions: [aliceSession]),
      pickleKey: pk,
      messageId: 'mX',
      ciphertext: base64Encode(cNew2.body),
      olmType: cNew2.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(result, 'new session');
    expect(fired, 1);
  });

  test('first contact with sender key', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobBefore),
      pickleKey: pk,
      messageId: 'm0',
      ciphertext: base64Encode(c0.body),
      olmType: c0.type,
      engine: olm,
      senderKey: aliceKey,
      senderId: aliceId,
      onStoredKey: () => fired++,
    );
    expect(result, 'first words');
    expect(fired, 1, reason: 'B1: the checked sk path may be saved');
  });

  test('failure: no stored session', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobBefore),
      pickleKey: pk,
      messageId: 'm1',
      ciphertext: base64Encode(c1.body),
      olmType: c1.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(result, null);
    expect(fired, 0);
  });

  test('failure: wrong pickle key', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobBefore),
      pickleKey: List.filled(32, 1),
      messageId: 'm1',
      ciphertext: base64Encode(c1.body),
      olmType: c1.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(result, null);
    expect(fired, 0);
  });

  test('sender key provided but stored session exists', () async {
    var fired = 0;
    final result = await peekDecrypt(
      rows: rows(account: bobAfter, sessions: [aliceSession]),
      pickleKey: pk,
      messageId: 'm1',
      ciphertext: base64Encode(c1.body),
      olmType: c1.type,
      engine: olm,
      senderKey: aliceKey,
      senderId: aliceId,
      onStoredKey: () => fired++,
    );
    expect(result, 'normal');
    expect(fired, 1);
  });

  test('onStoredKey fires at most once per call', () async {
    var fired = 0;
    await peekDecrypt(
      rows: rows(account: bobAfter, sessions: [aliceSession]),
      pickleKey: pk,
      messageId: 'm1',
      ciphertext: base64Encode(c1.body),
      olmType: c1.type,
      engine: olm,
      onStoredKey: () => fired++,
    );
    expect(fired, 1);
  });
}
