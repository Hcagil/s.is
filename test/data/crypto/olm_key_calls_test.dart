// Runs against the real compiled Rust library (vodozemac), not a fake.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/crypto/rust/api/olm.dart';
import 'package:sis/data/crypto/rust/frb_generated.dart';

void main() {
  setUpAll(() async => RustLib.init());

  test('pickle round trip', () async {
    final account = OlmAccount()..generateOneTimeKeys(count: 3);
    final key = List.generate(32, (i) => i);
    final pickle = account.pickle(key: key);
    final restored = OlmAccount.fromPickle(pickle: pickle, key: key);
    expect(restored.identityKey(), account.identityKey());
    expect(restored.ed25519Key(), account.ed25519Key());
    expect(
      restored.unpublishedOneTimeKeys(),
      unorderedEquals(account.unpublishedOneTimeKeys()),
    );
  });

  test('fromPickle with wrong key throws without exposing data', () async {
    final account = OlmAccount();
    final key = List.generate(32, (i) => i);
    final pickle = account.pickle(key: key);
    final wrongKey = List.generate(32, (i) => i + 1);
    expect(
      () => OlmAccount.fromPickle(pickle: pickle, key: wrongKey),
      throwsA(
        predicate(
          (e) =>
              !e.toString().contains(pickle) &&
              !e.toString().contains(wrongKey.toString()),
        ),
      ),
    );
  });

  test('pickle with invalid key lengths throws', () async {
    final account = OlmAccount();
    final key31 = List.generate(31, (i) => i);
    final key33 = List.generate(33, (i) => i);
    expect(() => account.pickle(key: key31), throwsA(anything));
    expect(() => account.pickle(key: key33), throwsA(anything));
    final pickle32 = account.pickle(key: List.generate(32, (i) => i));
    expect(
      () => OlmAccount.fromPickle(pickle: pickle32, key: key31),
      throwsA(
        predicate(
          (e) =>
              !e.toString().contains(pickle32) &&
              !e.toString().contains(key31.toString()),
        ),
      ),
    );
  });

  test('generateOneTimeKeys', () async {
    final account = OlmAccount();
    final keys = account.generateOneTimeKeys(count: 5);
    expect(keys.length, 5);
    expect(keys.toSet().length, 5);
    for (final k in keys) {
      expect(k.length, 43);
    }
    expect(account.unpublishedOneTimeKeys(), containsAll(keys));
    account.markKeysAsPublished();
    expect(account.unpublishedOneTimeKeys(), isEmpty);
    expect(account.unpublishedFallbackKey(), isNull);
    expect(account.storedOneTimeKeyCount(), 5);
  });

  test('maxOneTimeKeys', () async {
    final account = OlmAccount();
    expect(account.maxOneTimeKeys(), 50);
  });

  test('generateFallbackKey', () async {
    final account = OlmAccount();
    account.generateFallbackKey();
    final fallback = account.unpublishedFallbackKey();
    expect(fallback, isNotNull);
    final oneTimes = account.unpublishedOneTimeKeys();
    expect(oneTimes, isNot(contains(fallback)));
  });

  test('fallback kept after rotation', () async {
    final b = OlmAccount();
    b.generateFallbackKey();
    final f1 = b.unpublishedFallbackKey()!;
    b.markKeysAsPublished();
    final a = OlmAccount();
    final outbound = a.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: f1,
    );
    final ciphertext = outbound.encrypt(plaintext: utf8.encode('hi'));
    b.generateFallbackKey(); // rotation
    expect(b.unpublishedFallbackKey(), isNot(f1));
    final inbound = b.createInboundSession(
      theirIdentityKey: a.identityKey(),
      message: ciphertext,
    );
    expect(utf8.decode(inbound.plaintext), 'hi');
  });

  test('sign and olmVerify', () async {
    final a = OlmAccount();
    final sig = a.sign(message: 'm');
    olmVerify(signingKey: a.ed25519Key(), message: 'm', signature: sig);
    expect(
      () =>
          olmVerify(signingKey: a.ed25519Key(), message: 'm2', signature: sig),
      throwsA(anything),
    );
    final b = OlmAccount();
    final sigB = b.sign(message: 'm');
    expect(
      () =>
          olmVerify(signingKey: a.ed25519Key(), message: 'm', signature: sigB),
      throwsA(anything),
    );
    expect(
      () => olmVerify(signingKey: b.ed25519Key(), message: 'm', signature: sig),
      throwsA(anything),
    );
  });

  test('outbound with claimed one-time key round trip', () async {
    final b = OlmAccount();
    b.generateOneTimeKeys(count: 1);
    final oneTime = b.unpublishedOneTimeKeys().first;
    final a = OlmAccount();
    final outbound = a.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: oneTime,
    );
    final ciphertext = outbound.encrypt(plaintext: utf8.encode('hello'));
    final inbound = b.createInboundSession(
      theirIdentityKey: a.identityKey(),
      message: ciphertext,
    );
    expect(utf8.decode(inbound.plaintext), 'hello');
    final replyCipher = inbound.session.encrypt(
      plaintext: utf8.encode('reply'),
    );
    final replyPlain = outbound.decrypt(message: replyCipher);
    expect(utf8.decode(replyPlain), 'reply');
  });

  test('Session pickle round trip', () async {
    final a = OlmAccount();
    final b = OlmAccount();
    final outbound = a.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: b.generateOneTimeKeys(count: 1).first,
    );
    final key32 = List.generate(32, (i) => i);
    final sessionPickle = outbound.pickle(key: key32);
    final restored = OlmSession.fromPickle(pickle: sessionPickle, key: key32);
    final newCipher = restored.encrypt(plaintext: utf8.encode('msg2'));
    final inbound = b.createInboundSession(
      theirIdentityKey: a.identityKey(),
      message: newCipher,
    );
    expect(utf8.decode(inbound.plaintext), 'msg2');
  });
}
