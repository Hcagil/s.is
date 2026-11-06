// A forged half-set row (ciphertext without olm type, or the reverse) must
// look exactly like a locked text once its chat held one: never plain peer
// text. Same setup as the M2 cases in message_opener_sender_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../support/opener_fakes.dart';
import '../../support/security_code_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

Message _row(String id, int t, {String? cipher, int? olm, String? body}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: 'bob',
      body: body ?? lockedBodyPlaceholder,
      createdAt: at(t),
      ciphertext: cipher,
      olmType: olm,
    );

void main() {
  late ScriptEngine engine;
  late DriftMessageStore real;
  late FakeSecurityCodeStore memory;

  setUp(() async {
    final h = await StoreHarness.create();
    real = h.open(owner: 'me', key: await h.newKey());
    addTearDown(real.close);
    engine = ScriptEngine();
    memory = FakeSecurityCodeStore();
  });

  for (final (name, cipher, olm) in <(String, String?, int?)>[
    ('ciphertext without olm type', ct('h'), null),
    ('olm type without ciphertext', null, 1),
  ]) {
    test('$name, after a locked text: shows the locked placeholder', () async {
      engine.answer[ct('l1')] = () =>
          Ok(encodeEnvelope(id: 'l1', text: 'locked hello'));
      final o = StoreMessageOpener(
        me: () => 'me',
        engine: () => engine,
        store: () => real,
        peerKey: FakePeerKeys().call,
        memory: () => memory,
      );
      addTearDown(o.dispose);

      final out = await o.open([
        _row('l1', 1, cipher: ct('l1'), olm: 1),
        _row('h1', 2, cipher: cipher, olm: olm, body: 'forged peer text'),
      ]);

      expect(out[0].body, 'locked hello');
      expect(out[1].body, lockedBodyPlaceholder);
    });
  }
}
