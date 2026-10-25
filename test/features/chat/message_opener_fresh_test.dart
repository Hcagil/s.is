// t_93dcd3767e: a private chat does not trust a backdated plain message.
// In a chat that already held a locked text, a plain text from the peer
// shows locked when it is: new to this phone on a fresh path (live insert,
// change feed), whatever its date; stored only as the locked placeholder, on
// every path; or not stored and dated inside the range this phone already
// holds (syncState.contiguousFrom), on a history path. Every locked row seen
// marks the chat held (decrypted or not, own rows too). Written from the
// contract, never from the implementation; qa fakes, the REAL encrypted store.
// The range cases live in message_opener_range_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/shared_location.dart';

import '../../support/opener_fakes.dart';
import '../../support/security_code_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

Message locked(String id, {int t = 0, String sender = 'bob'}) => Message(
  id: id,
  conversationId: 'c1',
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
  String body = 'plain text',
  bool poll = false,
  bool contact = false,
  SharedLocation? location,
  String? stickerId,
  bool albumCard = false,
  String? albumId,
  String? attachmentPath,
  Map<String, dynamic>? adminMsg,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: sender,
  body: body,
  createdAt: at(t),
  poll: poll,
  contact: contact,
  location: location,
  stickerId: stickerId,
  albumCard: albumCard,
  albumId: albumId,
  attachmentPath: attachmentPath,
  adminMsg: adminMsg,
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

  StoreMessageOpener make({
    MessageStore? Function()? store,
    FakeSecurityCodeStore? mem,
  }) {
    final o = StoreMessageOpener(
      me: () => 'me',
      engine: () => engine,
      store: store ?? () => real,
      peerKey: FakePeerKeys().call,
      memory: () => mem ?? memory,
    );
    addTearDown(o.dispose);
    return o;
  }

  void opens(String id, String text) =>
      engine.answer[ct(id)] = () => Ok(encodeEnvelope(id: id, text: text));

  /// Holds chat c1 from t5 with a locked text that really opens.
  Future<void> hold() async {
    opens('l1', 'locked hello');
    await make().open([locked('l1', t: 5)]);
    expect(memory.held['c1'], at(5));
  }

  group('1-2 fresh path', () {
    test('1: a new backdated plain row on a fresh path shows locked', () async {
      await hold();
      final res = await make().open([
        plain('f1', t: 1, body: 'forged'),
      ], fresh: true);
      expect(res.single.body, lockedBodyPlaceholder);
    });

    test('2: a row stored with a readable body stays plain (fresh)', () async {
      await hold();
      await real.upsertAll([plain('s1', t: 1, body: 'old plain')]);
      final res = await make().open([
        plain('s1', t: 1, body: 'old plain'),
      ], fresh: true);
      expect(res.single.body, 'old plain');
    });

    test('2b: a stored readable row inside the held range stays plain on a '
        'history path', () async {
      await real.reconcilePage('c1', [
        plain('s2', t: 2, body: 'kept'),
      ], reachedStart: false);
      await hold();
      final res = await make().open([plain('s2', t: 2, body: 'kept')]);
      expect(res.single.body, 'kept');
    });

    test('control: the date rule still locks a plain row after held', () async {
      await hold();
      final res = await make().open([plain('late', t: 6, body: 'late')]);
      expect(res.single.body, lockedBodyPlaceholder);
    });
  });

  group('4 history path outside the range (accepted limit)', () {
    test('syncState with contiguousFrom null: date rule only', () async {
      await hold();
      final store = _Sync(real, const StoredSync());
      final res = await make(store: () => store)
          .open([plain('n1', t: 3, body: 'old')]);
      expect(res.single.body, 'old');
      expect(store.asked, isTrue, reason: 'the opener read the sync state');
    });
  });

  group('5 a stored placeholder copy is never trusted', () {
    for (final fresh in [true, false]) {
      test(
        'stored placeholder, plain re-delivered, fresh=$fresh -> locked',
        () async {
          await hold();
          await real.upsertAll([
            Message(
              id: 'g1',
              conversationId: 'c1',
              senderId: 'bob',
              body: lockedBodyPlaceholder,
              createdAt: at(1),
            ),
          ]);
          final res = await make().open([
            plain('g1', t: 1, body: 'forged'),
          ], fresh: fresh);
          expect(res.single.body, lockedBodyPlaceholder);
        },
      );
    }

    test('the guard output written as production writes it, then the 5 s '
        'overlap re-read and the next first-page read: still locked', () async {
      await hold();
      final o = make();
      // Live insert: the guard locks it, the sync writes the output.
      final live = await o.open([
        plain('g2', t: 1, body: 'forged'),
      ], fresh: true);
      expect(live.single.body, lockedBodyPlaceholder);
      await real.upsertAll(live);
      // Overlap re-read of the change feed (fresh again).
      final overlap = await o.open([
        plain('g2', t: 1, body: 'forged'),
      ], fresh: true);
      expect(overlap.single.body, lockedBodyPlaceholder);
      await real.upsertAll(overlap);
      // Next chat open: the first page (not fresh), reconciled to the store.
      final page = await make().open([plain('g2', t: 1, body: 'forged')]);
      expect(page.single.body, lockedBodyPlaceholder);
      await real.reconcilePage('c1', page, reachedStart: false);
      final stored = await real.newest('c1');
      expect(
        stored.firstWhere((m) => m.id == 'g2').body,
        lockedBodyPlaceholder,
      );
    });
  });

  group('6 store missing or failing: date rule only', () {
    test('store null', () async {
      memory.held['c1'] = at(5);
      final o = make(store: () => null);
      final before = await o.open([
        plain('n1', t: 1, body: 'no store'),
      ], fresh: true);
      expect(before.single.body, 'no store');
      final after = await o.open([
        plain('n2', t: 6, body: 'no store 2'),
      ], fresh: true);
      expect(after.single.body, lockedBodyPlaceholder);
    });

    test('every read throws (fresh)', () async {
      memory.held['c1'] = at(5);
      final o = make(store: () => _ReadThrows(real));
      final before = await o.open([
        plain('r1', t: 1, body: 'kept'),
      ], fresh: true);
      expect(before.single.body, 'kept');
      final after = await o.open([
        plain('r2', t: 6, body: 'late'),
      ], fresh: true);
      expect(after.single.body, lockedBodyPlaceholder);
    });

    test('syncState throws on a history path inside the range', () async {
      await real.reconcilePage('c1', [
        plain('p2', t: 2, body: 'kept'),
      ], reachedStart: false);
      await hold();
      final res = await make(store: () => _ReadThrows(real))
          .open([plain('r3', t: 3, body: 'kept 3')]);
      expect(res.single.body, 'kept 3');
    });
  });

  group('7 every locked row seen marks the chat held', () {
    test('an unreadable peer row', () async {
      engine.answer[ct('u1')] = () => const Err(UnreadableMessageFailure());
      final res = await make().open([locked('u1', t: 4)]);
      expect(res.single.body, lockedBodyPlaceholder);
      expect(memory.held['c1'], at(4));
    });

    test('a peer row waiting for a session', () async {
      engine.answer[ct('w1')] = () => const Err(SessionPendingFailure());
      await make().open([locked('w1', t: 4)]);
      expect(memory.held['c1'], at(4));
    });

    test('an own row, with and without a stored copy', () async {
      await real.upsertAll([plain('o1', t: 3, sender: 'me', body: 'mine')]);
      final res = await make().open([locked('o1', t: 3, sender: 'me')]);
      expect(res.single.body, 'mine');
      expect(memory.held['c1'], at(3));
      final other = FakeSecurityCodeStore();
      await make(mem: other).open([locked('o2', t: 2, sender: 'me')]);
      expect(other.held['c1'], at(2));
      expect(engine.calls, isEmpty, reason: 'own rows are never decrypted');
    });

    test('a row answered from its stored copy (app restart)', () async {
      opens('l2', 'from disk');
      await make(mem: FakeSecurityCodeStore()).open([locked('l2', t: 4)]);
      final res = await make().open([locked('l2', t: 4)]);
      expect(res.single.body, 'from disk');
      expect(engine.calls, hasLength(1), reason: 'served from the store');
      expect(memory.held['c1'], at(4));
    });

    test('a fresh install that saw only an unreadable row still guards a '
        'later backdated plain row', () async {
      engine.answer[ct('u2')] = () => const Err(UnreadableMessageFailure());
      await make().open([locked('u2', t: 5)]);
      final res = await make().open([
        plain('b1', t: 1, body: 'backdated'),
      ], fresh: true);
      expect(res.single.body, lockedBodyPlaceholder);
    });

    test(
      'control: a fresh install with no locked row trusts history',
      () async {
        final res = await make().open([plain('b2', t: 1, body: 'backdated')]);
        expect(res.single.body, 'backdated');
        expect(memory.held['c1'], isNull);
      },
    );
  });

  group('8 excluded kinds are never flagged', () {
    final kinds = <String, Message>{
      'poll': plain('x-poll', t: 3, poll: true, body: 'Lunch?'),
      'contact': plain('x-contact', t: 3, contact: true, body: 'Ayla'),
      'location': plain(
        'x-loc',
        t: 3,
        body: 'Cafe',
        location: const SharedLocation(lat: 41.0, lng: 29.0, name: 'Cafe'),
      ),
      'sticker': plain('x-st', t: 3, stickerId: 'st1', body: 'sticker'),
      'album card': plain(
        'x-al',
        t: 3,
        albumCard: true,
        albumId: 'al1',
        body: 'Cats',
      ),
      'captioned media': plain(
        'x-cap',
        t: 3,
        attachmentPath: 'c1/a2.jpg',
        body: 'caption',
      ),
      'admin note': plain('x-adm', t: 3, adminMsg: {'k': 'hi'}, body: 'note'),
      'own row': plain('x-own', t: 3, sender: 'me', body: 'own message'),
    };
    for (final fresh in [true, false]) {
      kinds.forEach((kind, msg) {
        test('$kind, fresh=$fresh, inside the held range', () async {
          await real.reconcilePage('c1', [
            plain('p2', t: 2, body: 'kept'),
          ], reachedStart: false);
          await hold();
          final res = await make().open([msg], fresh: fresh);
          expect(res.single.body, msg.body);
          expect(res.single.stickerId, msg.stickerId);
        });
      });
    }
  });
}

/// The real store, but syncState answers [state] and records that it was read.
class _Sync extends SlowStore {
  _Sync(super.real, this.state);
  final StoredSync? state;
  bool asked = false;

  @override
  Future<StoredSync?> syncState(String conversationId) async {
    asked = true;
    return state;
  }
}

/// A store whose every read throws (a broken disk); writes pass through.
class _ReadThrows extends SlowStore {
  _ReadThrows(super.real);

  @override
  Future<List<Message>> newest(String conversationId, {int limit = 50}) =>
      throw StateError('read failed');
  @override
  Future<List<Message>> older(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) => throw StateError('read failed');
  @override
  Future<List<Message>> around(
    String conversationId,
    String messageId, {
    int each = 50,
  }) => throw StateError('read failed');
  @override
  Future<List<Message>> search(
    String query, {
    String? conversationId,
    int limit = 100,
  }) => throw StateError('read failed');
  @override
  Future<StoredSync?> syncState(String conversationId) =>
      throw StateError('read failed');
}
