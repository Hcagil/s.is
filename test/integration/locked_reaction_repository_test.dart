@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/reaction_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_reaction_store.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_reaction_repository.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/reaction_envelope.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/supabase_key_directory.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/drift_stores.dart';
import '../support/key_directory_fakes.dart';
import '../support/reach.dart';

/// SupabaseReactionRepository's locked path against the REAL local Supabase,
/// with REAL Olm engines and REAL on-phone stores on both sides (the
/// StoreReactionOpener as main.dart gives it to the repository). Contract:
///  * setLockedReaction stores the ciphertext only (emoji NULL) and makes the
///    chat private; a plain set there is then DeniedFailure; a clear works;
///  * DeniedFailure in a chat that cannot be locked (a member without keys);
///  * reactions() / reactionUpdates() hand out OPENED reactions; a row that
///    cannot be opened is absent from reactions() and a removal on the feed;
///  * myReactionUsage adds this phone's own locked reactions;
///  * relockPlain is a compare-and-set on the caller's own
///    plain row: Ok(true) replaced it with the ciphertext, Ok(false) for a
///    removed or already locked row (unchanged); DeniedFailure where the chat
///    cannot be locked.
///
/// Fixtures (supabase/seed.sql allowlist): lr-ana, lr-ben publish keys;
/// lr-cy never does. Needs the Rust library built and a freshly reset stack.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _pw = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _pw);
  } on AuthException {
    await client.auth.signUp(email: email, password: _pw);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _id(SupabaseClient c) => c.auth.currentUser!.id;

T _ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => fail('expected Ok, got $failure'),
};

Failure? _failure(Result<Object?> r) => switch (r) {
  Err(:final failure) => failure,
  Ok() => null,
};

/// One phone: real store file, real Olm account published for [client].
class Phone {
  Phone._(this.client, this.dir, this.store, this.identityKey, this.engine);

  final SupabaseClient client;
  final Directory dir;
  final DriftMessageStore store;
  final String identityKey;
  final DriftSessionEngine engine;

  static Future<Phone> make(SupabaseClient client) async {
    final dir = await Directory.systemTemp.createTemp('lr-');
    final store = driftStore(_id(client), dir, 'ef' * 32);
    final olm = OlmKeyEngine();
    final account = await olm.create();
    account.generateOneTimeKeys(5);
    account.generateFallbackKey();
    final published = await SupabaseKeyDirectory(client).publish(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: account.sign(
        deviceStatement(_id(client), account.identityKey, account.signingKey),
      ),
      oneTimeKeys: account.unpublishedOneTimeKeys,
      fallbackKey: account.unpublishedFallbackKey,
    );
    expect(published, isA<Ok<int>>(), reason: 'publish failed: $published');
    account.markPublished();
    expect(
      await DriftOlmPickleStore(store).save(account.pickle(FakePickleKeys.key)),
      isTrue,
    );
    final engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: FakePickleKeys(),
    );
    return Phone._(client, dir, store, account.identityKey, engine);
  }

  /// The opener main.dart wires, over this phone; peer keys from the server.
  StoreReactionOpener opener() => StoreReactionOpener(
    me: () => _id(client),
    engine: () => engine,
    store: () => DriftReactionStore(store),
    peerKey: (id) => SupabaseKeyDirectory(client).identity(id),
  );

  SupabaseReactionRepository repo() =>
      SupabaseReactionRepository(client, opener: opener());

  Future<void> close() async {
    await store.close();
    await dir.delete(recursive: true);
  }
}

Future<Map<String, dynamic>?> _row(SupabaseClient as, String m, String u) => as
    .from('message_reactions')
    .select('emoji, ciphertext, olm_type')
    .eq('message_id', m)
    .eq('user_id', u)
    .maybeSingle();

Future<String> _message(SupabaseClient from, String conversationId) async {
  final r = await from
      .from('messages')
      .insert({
        'conversation_id': conversationId,
        'sender_id': _id(from),
        'body': 'react to me',
      })
      .select('id')
      .single();
  return r['id'] as String;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SupabaseClient ana, ben, cy;
  late Phone anaPhone, benPhone;
  late String ab, ac;
  late String m1, m2, m3, mc;
  var outbound = false;

  setUpAll(() async {
    ana = await _signedIn('lr-ana@mail.test');
    ben = await _signedIn('lr-ben@mail.test');
    cy = await _signedIn('lr-cy@mail.test');
    anaPhone = await Phone.make(ana);
    benPhone = await Phone.make(ben);
    Future<String> start(SupabaseClient from, SupabaseClient to) async {
      final repo = SupabaseChatRepository(from);
      var r = await repo.startDirectConversation(_id(to));
      if (r is Err) {
        await findTag(from, await tagOf(to), id: _id(to));
        r = await repo.startDirectConversation(_id(to));
      }
      return _ok(r);
    }

    ab = await start(ana, ben);
    ac = await start(ana, cy);
    // Every message first, while both chats are still plain.
    m1 = await _message(ben, ab);
    m2 = await _message(ben, ab);
    m3 = await _message(ben, ab);
    mc = await _message(cy, ac);
    // ben's own plain rows from before the lock (for relockPlain): one live
    // on m1, one removed on m2.
    final benRepo = SupabaseReactionRepository(ben);
    _ok(await benRepo.setReaction(m1, '👍'));
    _ok(await benRepo.setReaction(m2, '😂'));
    _ok(await benRepo.setReaction(m2, null));
  });

  tearDownAll(() async {
    await anaPhone.close();
    await benPhone.close();
    for (final c in [ana, ben, cy]) {
      await c.dispose();
    }
  });

  /// ana locks [emoji] for ben on [messageId] with her real engine.
  Future<({String ciphertext, int olmType})> anaLocks(
    String messageId,
    String emoji,
  ) async {
    if (!outbound) {
      final keys = _ok(await SupabaseKeyDirectory(ana).claim(_id(ben)));
      expect(keys, isNotNull, reason: 'ben has keys to claim');
      _ok(await anaPhone.engine.createOutbound(_id(ben), keys!));
      outbound = true;
    }
    final l = _ok(
      await anaPhone.engine.encrypt(
        _id(ben),
        encodeReactionEnvelope(
          messageId: messageId,
          userId: _id(ana),
          emoji: emoji,
        ),
        peerIdentityKey: benPhone.identityKey,
      ),
    );
    return (ciphertext: l.ciphertext, olmType: l.olmType);
  }

  test('a locked set stores only the ciphertext; ben\'s real phone opens it '
      'through reactions()', () async {
    final l = await anaLocks(m1, '🦊');
    expect(
      await anaPhone.repo().setLockedReaction(m1, l.ciphertext, l.olmType),
      isA<Ok<void>>(),
    );
    final raw = await _row(ben, m1, _id(ana));
    expect(raw, isNotNull);
    expect(raw!['emoji'], isNull);
    expect(raw['ciphertext'], l.ciphertext);
    expect(raw['olm_type'], l.olmType);

    final list = _ok(await benPhone.repo().reactions(ab));
    final mine = list.where((r) => r.messageId == m1 && r.userId == _id(ana));
    expect(mine.single.emoji, '🦊');
    expect(mine.single.ciphertext, isNull);
    // opened once: a second read (a fresh repository) still shows it
    final again = _ok(await benPhone.repo().reactions(ab));
    expect(
      again
          .where((r) => r.messageId == m1 && r.userId == _id(ana))
          .single
          .emoji,
      '🦊',
    );
  });

  test('the chat is private now: a plain set is DeniedFailure, a clear '
      'works and nulls every column', () async {
    expect(
      _failure(await anaPhone.repo().setReaction(m2, '👍')),
      isA<DeniedFailure>(),
    );
    expect(await _row(ben, m2, _id(ana)), isNull, reason: 'nothing written');
    expect(await anaPhone.repo().setReaction(m1, null), isA<Ok<void>>());
    expect(await _row(ben, m1, _id(ana)), {
      'emoji': null,
      'ciphertext': null,
      'olm_type': null,
    });
  });

  test('a chat that cannot be locked (cy has no keys): DeniedFailure; '
      'a plain set there works', () async {
    expect(
      _failure(
        await anaPhone.repo().setLockedReaction(mc, base64.encode([1, 2]), 1),
      ),
      isA<DeniedFailure>(),
    );
    expect(await anaPhone.repo().setReaction(mc, '👍'), isA<Ok<void>>());
    expect((await _row(cy, mc, _id(ana)))!['emoji'], '👍');
  });

  test('a row that cannot be opened is absent from reactions()', () async {
    expect(
      await anaPhone.repo().setLockedReaction(
        m3,
        base64.encode(List.filled(90, 9)),
        1,
      ),
      isA<Ok<void>>(),
    );
    final list = _ok(await benPhone.repo().reactions(ab));
    expect(
      list.where((r) => r.messageId == m3 && r.userId == _id(ana)),
      isEmpty,
    );
  });

  test('reactionUpdates: a locked set arrives opened; an unopenable one '
      'arrives as a removal', () async {
    final events = <Reaction>[];
    final stream = _ok(await benPhone.repo().reactionUpdates(ab));
    final sub = stream.listen(events.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(seconds: 1));

    final l = await anaLocks(m2, '🐝');
    _ok(await anaPhone.repo().setLockedReaction(m2, l.ciphertext, l.olmType));
    _ok(
      await anaPhone.repo().setLockedReaction(
        m3,
        base64.encode(List.filled(91, 8)),
        1,
      ),
    );
    final end = DateTime.now().add(const Duration(seconds: 20));
    bool has(String m) =>
        events.any((e) => e.messageId == m && e.userId == _id(ana));
    while (!(has(m2) && has(m3)) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      events.lastWhere((e) => e.messageId == m2 && e.userId == _id(ana)).emoji,
      '🐝',
    );
    final bad = events.lastWhere(
      (e) => e.messageId == m3 && e.userId == _id(ana),
    );
    expect(bad.emoji, isNull);
    expect(bad.ciphertext, isNull, reason: 'never shown as text');
  });

  test('myReactionUsage adds this phone\'s own locked reactions', () async {
    final opener = anaPhone.opener();
    final repo = SupabaseReactionRepository(ana, opener: opener);
    final before = _ok(await repo.myReactionUsage());
    await opener.rememberOwn(m2, _id(ana), 'TE9DS0VE', '🦉');
    final after = _ok(await repo.myReactionUsage());
    expect(after['🦉'], (before['🦉'] ?? 0) + 1);
  });

  test('relockPlain: ben\'s old plain row is re-locked once (true), then '
      'false; a removed row stays removed (false); a chat that cannot be '
      'locked is DeniedFailure', () async {
    final x = base64.encode(List.filled(60, 5));
    final y = base64.encode(List.filled(60, 6));
    final repo = benPhone.repo();
    expect(await _row(ana, m1, _id(ben)), {
      'emoji': '👍',
      'ciphertext': null,
      'olm_type': null,
    }, reason: 'fixture: ben\'s plain row from before the lock');

    expect(_ok(await repo.relockPlain(m1, x, 1)), isTrue);
    expect(await _row(ana, m1, _id(ben)), {
      'emoji': null,
      'ciphertext': x,
      'olm_type': 1,
    });
    expect(_ok(await repo.relockPlain(m1, y, 0)), isFalse);
    expect(
      (await _row(ana, m1, _id(ben)))!['ciphertext'],
      x,
      reason: 'an already locked row is never replaced',
    );

    expect(_ok(await repo.relockPlain(m2, y, 0)), isFalse);
    expect(await _row(ana, m2, _id(ben)), {
      'emoji': null,
      'ciphertext': null,
      'olm_type': null,
    }, reason: 'a removal is never undone');

    expect((await _row(cy, mc, _id(ana)))!['emoji'], '👍');
    expect(
      _failure(await anaPhone.repo().relockPlain(mc, x, 1)),
      isA<DeniedFailure>(),
    );
    expect((await _row(cy, mc, _id(ana)))!['emoji'], '👍');
  });
}
