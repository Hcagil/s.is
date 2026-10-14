// Runs against the real compiled Rust library (vodozemac), not a fake.
// `RustLib.init()` loads rust/target/release/librust_lib_sis.so (the
// generated ioDirectory), so build it first:
//   cargo build --release --manifest-path rust/Cargo.toml
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/crypto/rust/api/olm.dart';
import 'package:sis/data/crypto/rust/frb_generated.dart';

// OlmCiphertext.messageType: vodozemac/Matrix numbering (0 pre-key, 1 normal).
const normalType = 1;
const preKeyType = 0;

/// A fresh A→B session: A opened it with B's one-time key, B accepted the
/// first ("hi") message.
({
  OlmAccount a,
  OlmAccount b,
  OlmSession sa,
  OlmCiphertext first,
  OlmInbound inbound,
})
pair() {
  final a = OlmAccount();
  final b = OlmAccount();
  final sa = a.createOutboundSession(
    theirIdentityKey: b.identityKey(),
    theirOneTimeKey: b.generateOneTimeKey(),
  );
  final first = sa.encrypt(plaintext: utf8.encode('hi'));
  final inbound = b.createInboundSession(
    theirIdentityKey: a.identityKey(),
    message: first,
  );
  return (a: a, b: b, sa: sa, first: first, inbound: inbound);
}

bool containsSublist(List<int> hay, List<int> needle) {
  for (var i = 0; i <= hay.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

Uint8List b64(String key) => base64Decode(base64.normalize(key));

void main() {
  setUpAll(() async => RustLib.init());

  test('round trip: pre-key first message, then both directions', () {
    final p = pair();
    expect(p.first.messageType, preKeyType);
    expect(utf8.decode(p.inbound.plaintext), 'hi');

    final reply = p.inbound.session.encrypt(
      plaintext: utf8.encode('hello back'),
    );
    expect(reply.messageType, normalType);
    expect(utf8.decode(p.sa.decrypt(message: reply)), 'hello back');

    final second = p.sa.encrypt(plaintext: utf8.encode('second'));
    expect(second.messageType, normalType);
    expect(utf8.decode(p.inbound.session.decrypt(message: second)), 'second');
  });

  test('keys are base64 Curve25519 keys, distinct per account and call', () {
    final a = OlmAccount();
    final b = OlmAccount();
    expect(b64(a.identityKey()), hasLength(32));
    expect(a.identityKey(), a.identityKey());
    expect(a.identityKey(), isNot(b.identityKey()));
    final otk1 = a.generateOneTimeKey();
    final otk2 = a.generateOneTimeKey();
    expect(b64(otk1), hasLength(32));
    expect(otk1, isNot(otk2));
  });

  test('bad base64 identity key throws', () {
    final b = OlmAccount();
    expect(
      () => OlmAccount().createOutboundSession(
        theirIdentityKey: 'not base64!!',
        theirOneTimeKey: b.generateOneTimeKey(),
      ),
      throwsA(anything),
    );
  });

  test('bad base64 one-time key throws', () {
    final b = OlmAccount();
    expect(
      () => OlmAccount().createOutboundSession(
        theirIdentityKey: b.identityKey(),
        theirOneTimeKey: 'not base64!!',
      ),
      throwsA(anything),
    );
  });

  test('a normal message cannot open an inbound session', () {
    final p = pair();
    p.sa.decrypt(message: p.inbound.session.encrypt(plaintext: [1]));
    final normal = p.sa.encrypt(plaintext: utf8.encode('second'));
    expect(normal.messageType, normalType);
    expect(
      () => p.b.createInboundSession(
        theirIdentityKey: p.a.identityKey(),
        message: normal,
      ),
      throwsA(anything),
    );
  });

  test('a valid pre-key body relabelled as normal is refused', () {
    // Same receiver, same unused one-time key: only the type differs.
    final a = OlmAccount();
    final b = OlmAccount();
    final sa = a.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: b.generateOneTimeKey(),
    );
    final preKey = sa.encrypt(plaintext: utf8.encode('pre'));
    expect(
      () => b.createInboundSession(
        theirIdentityKey: a.identityKey(),
        message: OlmCiphertext(messageType: normalType, body: preKey.body),
      ),
      throwsA(anything),
    );
    // Control: the untouched message still opens the session.
    final ok = b.createInboundSession(
      theirIdentityKey: a.identityKey(),
      message: preKey,
    );
    expect(utf8.decode(ok.plaintext), 'pre');
  });

  test('garbage ciphertext throws', () {
    final p = pair();
    final garbage = Uint8List.fromList(List.filled(64, 7));
    expect(
      () => p.inbound.session.decrypt(
        message: OlmCiphertext(messageType: normalType, body: garbage),
      ),
      throwsA(anything),
    );
    expect(
      () => p.b.createInboundSession(
        theirIdentityKey: p.a.identityKey(),
        message: OlmCiphertext(messageType: preKeyType, body: garbage),
      ),
      throwsA(anything),
    );
    // Well-formed normal message, last (MAC) byte flipped.
    p.sa.decrypt(message: p.inbound.session.encrypt(plaintext: [1]));
    final real = p.sa.encrypt(plaintext: utf8.encode('tamper me'));
    expect(real.messageType, normalType);
    final tampered = Uint8List.fromList(real.body);
    tampered[tampered.length - 1] ^= 1;
    expect(
      () => p.inbound.session.decrypt(
        message: OlmCiphertext(messageType: real.messageType, body: tampered),
      ),
      throwsA(anything),
    );
    // The session survives the rejected input.
    final next = p.sa.encrypt(plaintext: utf8.encode('still here'));
    expect(utf8.decode(p.inbound.session.decrypt(message: next)), 'still here');
  });

  test('a one-time key opens only one inbound session', () {
    final a = OlmAccount();
    final a2 = OlmAccount();
    final b = OlmAccount();
    final otk = b.generateOneTimeKey();
    final sa = a.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: otk,
    );
    final sa2 = a2.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: otk,
    );
    final first = b.createInboundSession(
      theirIdentityKey: a.identityKey(),
      message: sa.encrypt(plaintext: utf8.encode('msg1')),
    );
    expect(utf8.decode(first.plaintext), 'msg1');
    expect(
      () => b.createInboundSession(
        theirIdentityKey: a2.identityKey(),
        message: sa2.encrypt(plaintext: utf8.encode('msg2')),
      ),
      throwsA(anything),
    );
  });

  test('the same pre-key message replayed is refused', () {
    final p = pair();
    expect(
      () => p.b.createInboundSession(
        theirIdentityKey: p.a.identityKey(),
        message: p.first,
      ),
      throwsA(anything),
    );
  });

  test('ciphertext does not contain the plaintext bytes', () {
    final p = pair();
    final plaintext = utf8.encode('attack at dawn, attack at dawn');
    final preKey = OlmAccount()
        .createOutboundSession(
          theirIdentityKey: p.b.identityKey(),
          theirOneTimeKey: p.b.generateOneTimeKey(),
        )
        .encrypt(plaintext: plaintext);
    final normal = p.inbound.session.encrypt(plaintext: plaintext);
    expect(preKey.messageType, preKeyType);
    expect(normal.messageType, normalType);
    expect(containsSublist(preKey.body, plaintext), isFalse);
    expect(containsSublist(normal.body, plaintext), isFalse);
    expect(utf8.decode(p.sa.decrypt(message: normal)), utf8.decode(plaintext));
  });

  test('two encryptions of the same text differ and both decrypt', () {
    final p = pair();
    final c1 = p.sa.encrypt(plaintext: utf8.encode('same'));
    final c2 = p.sa.encrypt(plaintext: utf8.encode('same'));
    expect(c1.body, isNot(equals(c2.body)));
    expect(utf8.decode(p.inbound.session.decrypt(message: c1)), 'same');
    expect(utf8.decode(p.inbound.session.decrypt(message: c2)), 'same');
  });

  test('the C entry for the iPhone notification helper reports success', () {
    // Same library the Swift probe links; 0 = the round trip worked.
    final selftest = DynamicLibrary.open(
      'rust/target/release/librust_lib_sis.so',
    ).lookupFunction<Int32 Function(), int Function()>('sis_olm_selftest');
    expect(selftest(), 0);
  });
}
