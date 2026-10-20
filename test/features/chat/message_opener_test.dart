// StoreMessageOpener (Private Chats 4a Group D), cases 1-10 of the receive
// path contract, written from the MessageOpener interface and that contract,
// never from the implementation. The engine and peerKey are qa fakes
// (test/support/opener_fakes.dart); the store is the REAL encrypted
// DriftMessageStore, behind a wrapper whose writes can be slowed down.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../support/opener_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

const me = 'me';
const bob = 'bob';
const carol = 'carol';

/// A locked row as the server sends it.
Message locked(
  String id, {
  String from = bob,
  int t = 0,
  String? cipher,
  int olmType = 1,
  MessageDeletion? deletion,
  DateTime? editedAt,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: lockedBodyPlaceholder,
  createdAt: at(t),
  ciphertext: cipher ?? ct(id),
  olmType: olmType,
  deletion: deletion,
  editedAt: editedAt,
);

Message plain(String id, {String body = 'plain', int t = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: bob,
  body: body,
  createdAt: at(t),
);

final card = LinkPreview(
  url: Uri.parse('https://example.test/a'),
  title: 'A page',
);

void main() {
  late ScriptEngine engine;
  late FakePeerKeys peerKeys;
  late DriftMessageStore real;
  late SlowStore store;
  String? whoAmI;
  late bool engineWired;

  setUp(() async {
    final h = await StoreHarness.create();
    real = h.open(owner: me, key: await h.newKey());
    addTearDown(real.close);
    store = SlowStore(real);
    engine = ScriptEngine();
    peerKeys = FakePeerKeys();
    whoAmI = me;
    engineWired = true;
  });

  StoreMessageOpener make() {
    final o = StoreMessageOpener(
      me: () => whoAmI,
      engine: () => engineWired ? engine : null,
      store: () => store,
      peerKey: peerKeys.call,
    );
    addTearDown(o.dispose);
    return o;
  }

  /// The engine opens [cipher] to the envelope of [id] with [text].
  void opens(String cipher, String id, String text, {LinkPreview? lp}) =>
      engine.answer[cipher] = () =>
          Ok(encodeEnvelope(id: id, text: text, card: lp));

  Future<Message?> stored(String id) async {
    for (final m in await real.newest('c1', limit: 500)) {
      if (m.id == id) return m;
    }
    return null;
  }

  void neverCiphertext(List<Message> out) {
    for (final m in out) {
      expect(m.ciphertext, isNull, reason: '${m.id} came back locked');
    }
  }

  group('1 what is locked', () {
    test('plain, deleted-locked and half-locked rows pass unchanged, '
        'the same instances, and nothing is decrypted', () async {
      final rows = [
        plain('p1'),
        locked('d1', deletion: MessageDeletion.vanished),
        Message(
          id: 'h1',
          conversationId: 'c1',
          senderId: bob,
          body: 'x',
          createdAt: at(2),
          ciphertext: ct('h1'),
        ),
      ];
      final out = await make().open(rows);
      expect(out, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(identical(out[i], rows[i]), isTrue, reason: rows[i].id);
      }
      expect(engine.calls, isEmpty);
    });

    test(
      'a plain row next to a locked one is still the same instance',
      () async {
        opens(ct('m1'), 'm1', 'hi');
        final rows = [plain('p1'), locked('m1', t: 1)];
        final out = await make().open(rows);
        expect(identical(out[0], rows[0]), isTrue);
        expect(out[1].body, 'hi');
      },
    );
  });

  group('2 opening a row from another member', () {
    test(
      'decrypt gets the sender, the directory key, ciphertext and type; '
      'text and card become body and linkPreview; sealed is the hash',
      () async {
        opens(ct('m1'), 'm1', 'hi there', lp: card);
        final out = await make().open([locked('m1')]);
        expect(engine.calls, [
          (
            peer: bob,
            identityKey: identityOf(bob),
            ciphertext: ct('m1'),
            olmType: 1,
          ),
        ]);
        expect(peerKeys.calls, contains(bob));
        final m = out.single;
        expect(m.id, 'm1');
        expect(m.body, 'hi there');
        expect(m.linkPreview?.url, card.url);
        expect(m.linkPreview?.title, card.title);
        expect(m.ciphertext, isNull);
        expect(m.olmType, isNull);
        expect(sealsOf(ct('m1')), contains(m.sealed));
      },
    );

    test('the opened row is in the store BEFORE open returns, even when the '
        'disk is slow', () async {
      store.writeDelay = const Duration(milliseconds: 300);
      opens(ct('m1'), 'm1', 'survives a crash');
      await make().open([locked('m1')]);
      // No waiting: a fire-and-forget write would not have landed yet.
      final s = await stored('m1');
      expect(s?.body, 'survives a crash');
      expect(sealsOf(ct('m1')), contains(s?.sealed));
    });
  });

  group('3 decrypt once', () {
    test('a second open of the same row answers from memory', () async {
      opens(ct('m1'), 'm1', 'once');
      final o = make();
      await o.open([locked('m1')]);
      final again = await o.open([locked('m1')]);
      expect(again.single.body, 'once');
      expect(engine.calls, hasLength(1));
    });

    test(
      'a fresh opener (app restart) answers from the stored sealed row',
      () async {
        opens(ct('m1'), 'm1', 'from disk');
        await make().open([locked('m1')]);
        final out = await make().open([locked('m1')]);
        expect(out.single.body, 'from disk');
        expect(out.single.ciphertext, isNull);
        expect(engine.calls, hasLength(1));
      },
    );

    test('a stored readable row WITHOUT the matching seal is not trusted: '
        'it is decrypted', () async {
      await real.upsertAll([plain('m1', body: 'old plain copy')]);
      opens(ct('m1'), 'm1', 'the real text');
      final out = await make().open([locked('m1')]);
      expect(engine.calls, hasLength(1));
      expect(out.single.body, 'the real text');
    });

    test('duplicate delivery in one list opens once; both copies readable; '
        'the store holds one row', () async {
      opens(ct('m1'), 'm1', 'dup');
      final out = await make().open([locked('m1'), locked('m1')]);
      expect(engine.calls, hasLength(1));
      expect(out.map((m) => m.body), ['dup', 'dup']);
      final ids = [for (final m in await real.newest('c1')) m.id];
      expect(ids.where((i) => i == 'm1'), hasLength(1));
    });
  });

  group('4 edits', () {
    test('a new ciphertext for the same id is decrypted again and replaces '
        'the text', () async {
      opens(ct('v1'), 'm1', 'first');
      opens(ct('v2'), 'm1', 'second');
      final o = make();
      await o.open([locked('m1', cipher: ct('v1'))]);
      final out = await o.open([
        locked('m1', cipher: ct('v2'), editedAt: at(5)),
      ]);
      expect(engine.decrypted, [ct('v1'), ct('v2')]);
      expect(out.single.body, 'second');
      expect(sealsOf(ct('v2')), contains(out.single.sealed));
      expect((await stored('m1'))?.body, 'second');
    });

    test('an edit that cannot be opened keeps the old stored text (same '
        'opener and after a restart)', () async {
      opens(ct('v1'), 'm1', 'first');
      // ct('v2') has no answer: Unreadable.
      final o = make();
      await o.open([locked('m1', cipher: ct('v1'))]);
      final edit = locked('m1', cipher: ct('v2'), editedAt: at(5));
      final out = await o.open([edit]);
      expect(out.single.body, 'first');
      expect(out.single.ciphertext, isNull);
      final restarted = await make().open([edit]);
      expect(restarted.single.body, 'first');
      expect(restarted.single.ciphertext, isNull);
      expect((await stored('m1'))?.body, 'first');
    });
  });

  group('5 pre-key first message', () {
    test('olmType 0 is handed to decrypt and its text shows', () async {
      opens(ct('m0'), 'm0', 'hello first');
      final out = await make().open([locked('m0', olmType: 0)]);
      expect(engine.calls.single.olmType, 0);
      expect(out.single.body, 'hello first');
    });
  });

  group('6 out-of-order delivery', () {
    test('opened oldest createdAt first, ties by position; results in the '
        'original order', () async {
      for (final id in ['a', 'b', 'c', 'd']) {
        opens(ct(id), id, 'text $id');
      }
      final rows = [
        locked('c', t: 3),
        locked('a', t: 1),
        locked('d', t: 3),
        locked('b', t: 2),
      ];
      final out = await make().open(rows);
      expect(engine.decrypted, [ct('a'), ct('b'), ct('c'), ct('d')]);
      expect(out.map((m) => m.id), ['c', 'a', 'd', 'b']);
      expect(out.map((m) => m.body), ['text c', 'text a', 'text d', 'text b']);
    });
  });

  group('7 no session yet', () {
    test('SessionPending: placeholder, ciphertext cleared, not cached as '
        'failed (a later fetch decrypts again and opens it)', () async {
      var session = false;
      engine.answer[ct('m1')] = () => session
          ? Ok(encodeEnvelope(id: 'm1', text: 'late'))
          : const Err(SessionPendingFailure());
      final o = make();
      final first = await o.open([locked('m1')]);
      expect(first.single.body, lockedBodyPlaceholder);
      neverCiphertext(first);
      expect(await stored('m1'), isNull, reason: 'nothing stored for it');
      session = true;
      final later = await o.open([locked('m1')]);
      expect(later.single.body, 'late');
      expect(engine.calls, hasLength(2));
    });

    test('a later pre-key message of the same sender retries the waiting '
        'rows; each that opens is emitted on reopened and stored', () async {
      var session = false;
      engine.answer[ct('w1')] = () => session
          ? Ok(encodeEnvelope(id: 'w1', text: 'waited'))
          : const Err(SessionPendingFailure());
      engine.answer[ct('k0')] = () {
        session = true;
        return Ok(encodeEnvelope(id: 'k0', text: 'key'));
      };
      final o = make();
      final got = <Message>[];
      final sub = o.reopened.listen(got.add);
      addTearDown(sub.cancel);
      final first = await o.open([locked('w1', t: 1)]);
      expect(first.single.body, lockedBodyPlaceholder);

      final out = await o.open([locked('k0', t: 2, olmType: 0)]);
      expect(out.single.body, 'key');
      await pumpUntil(() => got.isNotEmpty);
      expect(got.single.id, 'w1');
      expect(got.single.body, 'waited');
      expect(got.single.ciphertext, isNull);
      await pumpUntil(() async => (await stored('w1'))?.body == 'waited');
    });

    test('a pre-key message of ANOTHER sender does not retry them', () async {
      engine.answer[ct('w1')] = () => const Err(SessionPendingFailure());
      opens(ct('k0'), 'k0', 'carol key');
      final o = make();
      final got = <Message>[];
      final sub = o.reopened.listen(got.add);
      addTearDown(sub.cancel);
      await o.open([locked('w1')]);
      await o.open([locked('k0', from: carol, olmType: 0)]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(engine.decrypted.where((c) => c == ct('w1')), hasLength(1));
      expect(got, isEmpty);
    });

    test(
      'peerKey offline (Err) or no phone (Ok(null)): placeholder, no '
      'decrypt, and it opens on a later fetch once the key is there',
      () async {
        opens(ct('m1'), 'm1', 'after the key');
        opens(ct('m2'), 'm2', 'after the phone');
        peerKeys.answer[bob] = const Err(
          NetworkFailure('off', retryable: true),
        );
        peerKeys.answer[carol] = const Ok(null);
        final o = make();
        final out = await o.open([
          locked('m1'),
          locked('m2', from: carol, t: 1),
        ]);
        expect(out.map((m) => m.body), [
          lockedBodyPlaceholder,
          lockedBodyPlaceholder,
        ]);
        neverCiphertext(out);
        expect(engine.calls, isEmpty, reason: 'no key, no decrypt');
        peerKeys.answer.clear();
        final later = await o.open([
          locked('m1'),
          locked('m2', from: carol, t: 1),
        ]);
        expect(later.map((m) => m.body), ['after the key', 'after the phone']);
      },
    );

    test('the waiting list keeps at most 200 rows', () async {
      var session = false;
      for (var i = 0; i < 205; i++) {
        engine.answer[ct('w$i')] = () => session
            ? Ok(encodeEnvelope(id: 'w$i', text: 't$i'))
            : const Err(SessionPendingFailure());
      }
      engine.answer[ct('k0')] = () {
        session = true;
        return Ok(encodeEnvelope(id: 'k0', text: 'key'));
      };
      final o = make();
      final got = <Message>[];
      final sub = o.reopened.listen(got.add);
      addTearDown(sub.cancel);
      await o.open([for (var i = 0; i < 205; i++) locked('w$i', t: i)]);
      await o.open([locked('k0', t: 999, olmType: 0)]);
      await pumpUntil(() => got.length >= 200);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(got, hasLength(200));
    });
  });

  group('8 final failures', () {
    test(
      'Unreadable: placeholder, cached for the run (no second decrypt)',
      () async {
        final o = make();
        final out = await o.open([locked('m1')]); // no answer: Unreadable
        expect(out.single.body, lockedBodyPlaceholder);
        neverCiphertext(out);
        await o.open([locked('m1')]);
        expect(engine.calls, hasLength(1));
      },
    );

    test('an envelope that is not valid, or carries another id: placeholder, '
        'cached', () async {
      engine.answer[ct('bad')] = () => const Ok('not json at all');
      engine.answer[ct('replay')] = () =>
          Ok(encodeEnvelope(id: 'some-other-row', text: 'replayed'));
      final o = make();
      final rows = [locked('bad'), locked('replay', t: 1)];
      final out = await o.open(rows);
      expect(out.map((m) => m.body), [
        lockedBodyPlaceholder,
        lockedBodyPlaceholder,
      ]);
      neverCiphertext(out);
      await o.open(rows);
      expect(engine.calls, hasLength(2), reason: 'each decrypted once');
    });

    test('another Err (store error): placeholder, NOT cached', () async {
      var fail = true;
      engine.answer[ct('m1')] = () => fail
          ? const Err(SessionStoreFailure())
          : Ok(encodeEnvelope(id: 'm1', text: 'second try'));
      final o = make();
      final out = await o.open([locked('m1')]);
      expect(out.single.body, lockedBodyPlaceholder);
      fail = false;
      final again = await o.open([locked('m1')]);
      expect(engine.calls, hasLength(2));
      expect(again.single.body, 'second try');
    });

    test('a throwing engine never makes open throw', () async {
      engine.throwFor.add(ct('m1'));
      opens(ct('m2'), 'm2', 'fine');
      final out = await make().open([locked('m1'), locked('m2', t: 1)]);
      expect(out.map((m) => m.body), [lockedBodyPlaceholder, 'fine']);
      neverCiphertext(out);
    });

    test('a throwing peerKey never makes open throw', () async {
      final o = StoreMessageOpener(
        me: () => me,
        engine: () => engine,
        store: () => store,
        peerKey: (_) => Future.error(StateError('directory crashed')),
      );
      addTearDown(o.dispose);
      final out = await o.open([locked('m1')]);
      expect(out.single.body, lockedBodyPlaceholder);
      neverCiphertext(out);
    });
  });

  group('9 own rows', () {
    test('never decrypted; the stored plaintext and card come back', () async {
      await real.upsertAll([
        Message(
          id: 'o1',
          conversationId: 'c1',
          senderId: me,
          body: 'my own words',
          createdAt: at(0),
          linkPreview: card,
        ),
      ]);
      opens(ct('o1'), 'o1', 'must not be used');
      final out = await make().open([locked('o1', from: me)]);
      expect(engine.calls, isEmpty);
      expect(out.single.body, 'my own words');
      expect(out.single.linkPreview?.url, card.url);
      neverCiphertext(out);
    });

    test(
      'without a stored copy (or only a placeholder): the placeholder',
      () async {
        await real.upsertAll([
          Message(
            id: 'o2',
            conversationId: 'c1',
            senderId: me,
            body: lockedBodyPlaceholder,
            createdAt: at(1),
          ),
        ]);
        opens(ct('o1'), 'o1', 'must not be used');
        final out = await make().open([
          locked('o1', from: me),
          locked('o2', from: me, t: 1),
        ]);
        expect(engine.calls, isEmpty);
        expect(out.map((m) => m.body), [
          lockedBodyPlaceholder,
          lockedBodyPlaceholder,
        ]);
        neverCiphertext(out);
      },
    );
  });

  group('10 unwired', () {
    test(
      'engine null: locked rows get the placeholder, plain rows pass',
      () async {
        engineWired = false;
        final rows = [plain('p1'), locked('m1', t: 1)];
        final out = await make().open(rows);
        expect(identical(out[0], rows[0]), isTrue);
        expect(out[1].body, lockedBodyPlaceholder);
        neverCiphertext([out[1]]);
      },
    );

    test('me null: placeholder, nothing decrypted', () async {
      whoAmI = null;
      opens(ct('m1'), 'm1', 'hidden');
      final out = await make().open([locked('m1')]);
      expect(out.single.body, lockedBodyPlaceholder);
      neverCiphertext(out);
      expect(engine.calls, isEmpty);
    });
  });
}

/// Polls [done] (sync or async) until true; fails after 5 s.
Future<void> pumpUntil(FutureOr<bool> Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
