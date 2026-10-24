// Audit t_79e9672198 findings M1 and M2 on the receive path, written from the
// t_a9ef0f411f contract (Fix 1, Fix 2) and the security gate's corrected F1
// list, never from the implementation. qa fakes for the engine and peerKey
// (test/support/opener_fakes.dart), the qa memory fake
// (test/support/security_code_fakes.dart), the REAL encrypted DriftMessageStore.
//
// M1: a stored text keeps the sender it was opened for; a server that later
//     sends the same row under another sender_id never relabels it.
// M2: a plain row from the peer created after the chat first held a locked
//     text gets the locked look (an evil server could slip it in).
//     Not flagged: own rows, attachments (known gap R1), deleted or empty
//     rows, rows before the first locked text, other chats, and (F1) the kinds
//     that stay plain by design in an encrypted chat: polls, shared contacts,
//     shared locations, stickers, sticker album cards.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/shared_location.dart';

import '../../support/opener_fakes.dart';
import '../../support/security_code_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

Message locked(
  String id, {
  int t = 0,
  String sender = 'bob',
  String conv = 'c1',
}) => Message(
  id: id,
  conversationId: conv,
  senderId: sender,
  body: lockedBodyPlaceholder,
  createdAt: at(t),
  ciphertext: ct(id),
  olmType: 1,
);

Message plain(
  String id, {
  int t = 0,
  String sender = 'bob',
  String conv = 'c1',
  String body = 'plain text',
}) => Message(
  id: id,
  conversationId: conv,
  senderId: sender,
  body: body,
  createdAt: at(t),
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

  StoreMessageOpener make() {
    final o = StoreMessageOpener(
      me: () => 'me',
      engine: () => engine,
      store: () => real,
      peerKey: FakePeerKeys().call,
      memory: () => memory,
    );
    addTearDown(o.dispose);
    return o;
  }

  void opens(String id, String text) =>
      engine.answer[ct(id)] = () => Ok(encodeEnvelope(id: id, text: text));

  group('M1: a stored text keeps its sender', () {
    Future<void> openedFromBob() async {
      opens('m1', 'secret of bob');
      final first = await make().open([locked('m1')]);
      expect(first.single.body, 'secret of bob');
      expect(first.single.senderId, 'bob');
    }

    for (final (who, label) in [('carol', 'another member'), ('me', 'me')]) {
      test(
        'the server later says sender = $label: the stored row comes back '
        'as it is, never as $label\'s text (new opener: stored copy)',
        () async {
          await openedFromBob();
          final out = await make().open([locked('m1', sender: who)]);
          expect(out.single.senderId, 'bob');
          expect(
            out.single.senderId == who && out.single.body == 'secret of bob',
            isFalse,
          );
        },
      );

      test('the same opener (memory of this run) sends it again under '
          '$label: not relabelled', () async {
        opens('m1', 'secret of bob');
        final o = make();
        expect((await o.open([locked('m1')])).single.body, 'secret of bob');
        final out = await o.open([locked('m1', sender: who)]);
        expect(out.single.senderId, 'bob');
      });
    }

    test('control: the same sender again still gets its stored text', () async {
      await openedFromBob();
      final out = await make().open([locked('m1')]);
      expect(out.single.body, 'secret of bob');
      expect(out.single.senderId, 'bob');
    });
  });

  group('M2: a plain text after a locked one in that chat', () {
    Future<List<Message>> afterLocked(Message row) async {
      opens('l1', 'locked hello');
      return make().open([locked('l1', t: 1), row]);
    }

    test('a plain text from the peer after the first locked text shows the '
        'locked placeholder', () async {
      final out = await afterLocked(plain('p2', t: 2, body: 'slipped in'));
      expect(out[0].body, 'locked hello');
      expect(out[1].body, lockedBodyPlaceholder);
      expect(out[1].body, isNot('slipped in'));
    });

    test('remembered across calls and openers (memory of the chat)', () async {
      opens('l1', 'locked hello');
      await make().open([locked('l1', t: 1)]);
      expect(memory.held['c1'], isNotNull);
      final out = await make().open([plain('p2', t: 2, body: 'slipped in')]);
      expect(out.single.body, lockedBodyPlaceholder);
    });

    test(
      'a plain text from before the first locked one shows normally',
      () async {
        final out = await afterLocked(plain('p0', t: 0, body: 'old plain'));
        expect(out[1].body, 'old plain');
      },
    );

    test(
      'own plain text, deleted row, empty body, other chat: normal',
      () async {
        final out = await afterLocked(
          plain('p2', t: 2, sender: 'me', body: 'mine'),
        );
        expect(out[1].body, 'mine');
        final other = await make().open([
          plain('o2', t: 3, conv: 'c2', body: 'other chat'),
          plain('e2', t: 3, body: ''),
          Message(
            id: 'd2',
            conversationId: 'c1',
            senderId: 'bob',
            body: '',
            createdAt: at(3),
            deletion: MessageDeletion.placeholder,
          ),
        ]);
        expect(other[0].body, 'other chat');
        expect(other[1].body, '');
        expect(other[2].isDeleted, isTrue);
      },
    );

    test('as built (known gap R1): an attachment with a caption is not '
        'flagged', () async {
      final out = await afterLocked(
        Message(
          id: 'a2',
          conversationId: 'c1',
          senderId: 'bob',
          body: 'caption',
          createdAt: at(2),
          attachmentPath: 'c1/a2.jpg',
        ),
      );
      expect(out[1].body, 'caption');
    });

    // F1 (security gate, corrected contract): plain by design in an encrypted
    // chat, same list as the server trigger. Expected red until the fix round.
    final byDesign = <String, Message>{
      'poll': Message(
        id: 'k2',
        conversationId: 'c1',
        senderId: 'bob',
        body: 'Lunch?',
        createdAt: at(2),
        poll: true,
      ),
      'shared contact': Message(
        id: 'k2',
        conversationId: 'c1',
        senderId: 'bob',
        body: 'Ayla\n+90 555 000 0000',
        createdAt: at(2),
        contact: true,
      ),
      'shared location': Message(
        id: 'k2',
        conversationId: 'c1',
        senderId: 'bob',
        body: 'Cafe',
        createdAt: at(2),
        location: const SharedLocation(lat: 41.0, lng: 29.0, name: 'Cafe'),
      ),
      'sticker album card': Message(
        id: 'k2',
        conversationId: 'c1',
        senderId: 'bob',
        body: 'Cats',
        createdAt: at(2),
        albumCard: true,
        albumId: 'al1',
      ),
    };
    byDesign.forEach((kind, row) {
      test(
        'F1 (expected red, fix pending): a $kind from the peer after a locked text shows normally',
        () async {
          final out = await afterLocked(row);
          expect(out[1].body, row.body);
        },
      );
    });

    test('F1: a sticker from the peer after a locked text is not turned '
        'into a locked text', () async {
      final out = await afterLocked(
        Message(
          id: 's2',
          conversationId: 'c1',
          senderId: 'bob',
          body: '',
          createdAt: at(2),
          stickerId: 'st1',
        ),
      );
      expect(out[1].body, '');
      expect(out[1].stickerId, 'st1');
    });
  });
}
