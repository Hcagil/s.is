@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/text_locker.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_send_queue_store.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/supabase_key_directory.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/drift_stores.dart';
import '../support/fakes.dart';
import '../support/key_directory_fakes.dart';
import '../support/reach.dart';
import '../support/video_fakes.dart';

/// The encrypted send path through the real stack (Private Chats 4a Group
/// C): ana's SendQueueController wired as main.dart wires it -- TextLocker,
/// DriftSessionEngine (REAL vodozemac) over the real encrypted store, the
/// queue in that store, SupabaseKeyDirectory and
/// SupabaseEncryptedMessageRepository over the local Supabase -- and ben's own
/// real engine opening what arrived. Plus SupabaseEncryptedMessageRepository's
/// contract against the real database: a retried insert (23505) is Ok only
/// when the stored row is ours with the same ciphertext, conversation and
/// reply target; every other refusal is DeniedFailure; offline is retryable.
///
/// Fixtures (supabase/seed.sql allowlist): es-ana, es-ben, es-dan publish
/// keys; es-cy never does (so her chat with ana stays plain).
///
/// Needs the Rust library built and a freshly reset stack: every run claims
/// one of ben's keys, and claims are rate limited (RLMT1).
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

/// One phone: a real store file, a real Olm account published for [client].
class Phone {
  Phone._(this.client, this.dir, this.store, this.identityKey, this.engine);

  final SupabaseClient client;
  final Directory dir;
  final DriftMessageStore store;
  final String identityKey;
  final DriftSessionEngine engine;

  static final storeKey = 'cd' * 32;

  static Future<Phone> make(SupabaseClient client) async {
    final dir = await Directory.systemTemp.createTemp('es-');
    final store = driftStore(_id(client), dir, storeKey);
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

  Future<void> close() async {
    await store.close();
    await dir.delete(recursive: true);
  }
}

/// ana's app, wired as main.dart wires the send path, over [phone]'s store.
ProviderContainer _app(Phone phone) {
  final member = Member(userId: _id(phone.client), displayName: 'es');
  // As main.dart: the queue and its ciphertexts in the phone's own store.
  final queue = DriftSendQueueStore(phone.store);
  final c = ProviderContainer(
    overrides: [
      ...videoOverrides(store: queue),
      queuedCiphertextsProvider.overrideWithValue(queue),
      messageStoreProvider.overrideWithValue(phone.store),
      chatRepositoryProvider.overrideWithValue(
        SupabaseChatRepository(phone.client),
      ),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      sessionControllerProvider.overrideWith(
        () => DrivenSession(Allowed(member)),
      ),
      keyEngineProvider.overrideWithValue(OlmKeyEngine()),
      keyDirectoryProvider.overrideWithValue(
        SupabaseKeyDirectory(phone.client),
      ),
      sessionEngineProvider.overrideWithValue(phone.engine),
      encryptedMessageRepositoryProvider.overrideWithValue(
        SupabaseEncryptedMessageRepository(phone.client),
      ),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(currentUserIdProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  return c;
}

Future<void> _until(bool Function() done, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Map<String, dynamic>?> _row(SupabaseClient as, String id) => as
    .from('messages')
    .select('id, sender_id, body, ciphertext, olm_type, link_preview')
    .eq('id', id)
    .maybeSingle();

Failure? _failure(Result<Object?> r) => switch (r) {
  Err(:final failure) => failure,
  Ok() => null,
};

String _newId() => randomMessageId();

void main() {
  late SupabaseClient ana, ben, cy, dan;
  late Phone anaPhone, benPhone, danPhone;
  late String ab, ac, ad, db;

  setUpAll(() async {
    ana = await _signedIn('es-ana@mail.test');
    ben = await _signedIn('es-ben@mail.test');
    cy = await _signedIn('es-cy@mail.test');
    dan = await _signedIn('es-dan@mail.test');
    anaPhone = await Phone.make(ana);
    benPhone = await Phone.make(ben);
    danPhone = await Phone.make(dan);
    // Tag searches are rate limited (RLMT1): search only when the chat
    // cannot be started yet (a rerun on the same stack has found them).
    Future<String> start(SupabaseClient from, SupabaseClient to) async {
      final repo = SupabaseChatRepository(from);
      var r = await repo.startDirectConversation(_id(to));
      if (r is Err) {
        await findTag(from, await tagOf(to), id: _id(to));
        r = await repo.startDirectConversation(_id(to));
      }
      return switch (r) {
        Ok(:final value) => value,
        Err(:final failure) => fail('start chat: $failure'),
      };
    }

    ab = await start(ana, ben);
    ac = await start(ana, cy);
    ad = await start(ana, dan);
    db = await start(dan, ben);
  });

  tearDownAll(() async {
    for (final p in [anaPhone, benPhone, danPhone]) {
      await p.close();
    }
    for (final c in [ana, ben, cy, dan]) {
      await c.dispose();
    }
  });

  group('the send path, end to end', () {
    late ProviderContainer app;
    setUpAll(() => app = _app(anaPhone));
    tearDownAll(() => app.dispose());

    test('ana queues a text to ben: the server holds ONLY the ciphertext, '
        'ben\'s real engine opens it to the exact envelope', () async {
      await app.read(sessionControllerProvider.future);
      const text = 'meet at the bridge 😀\nbring water';
      final m = app.read(sendQueueProvider.notifier).enqueue(ab, body: text);
      await _until(
        () => (app.read(sendQueueProvider)[ab] ?? const []).isEmpty,
        'the queue to drain',
      );
      expect(
        app.read(draftsProvider.notifier).consumeFailure(ab),
        isNull,
        reason: 'the send failed',
      );

      final row = await _row(ben, m.id);
      expect(row, isNotNull, reason: 'ben cannot see the row');
      expect(row!['sender_id'], _id(ana));
      expect(row['body'], lockedBodyPlaceholder);
      expect(row['link_preview'], isNull);
      expect(row['ciphertext'], isNot(contains('bridge')));
      expect(row['olm_type'], 0, reason: 'the first message opens a session');

      final opened = await benPhone.engine.decrypt(
        peerUserId: _id(ana),
        peerIdentityKey: anaPhone.identityKey,
        ciphertext: row['ciphertext'] as String,
        olmType: row['olm_type'] as int,
      );
      final plain = switch (opened) {
        Ok(:final value) => value,
        Err(:final failure) => fail('ben could not open it: $failure'),
      };
      expect(jsonDecode(plain), {'v': 1, 'i': m.id, 't': text, 'lp': null});

      // The queue row (and its ciphertext) left with the item.
      final q = DriftSendQueueStore(anaPhone.store);
      expect(await q.load(_id(ana)), isEmpty);
      expect(await q.ciphertextOf(_id(ana), m.id), isNull);
    });

    test('a second text on the same session: ben opens it too', () async {
      final m = app
          .read(sendQueueProvider.notifier)
          .enqueue(ab, body: 'second one');
      await _until(
        () => (app.read(sendQueueProvider)[ab] ?? const []).isEmpty,
        'the queue to drain',
      );
      final row = (await _row(ben, m.id))!;
      expect(row['body'], lockedBodyPlaceholder);
      final opened = await benPhone.engine.decrypt(
        peerUserId: _id(ana),
        peerIdentityKey: anaPhone.identityKey,
        ciphertext: row['ciphertext'] as String,
        olmType: row['olm_type'] as int,
      );
      expect(switch (opened) {
        Ok(:final value) => (jsonDecode(value) as Map)['t'],
        Err(:final failure) => failure,
      }, 'second one');
    });

    test('cy has no keys: the old plain send, no ciphertext', () async {
      final m = app.read(sendQueueProvider.notifier).enqueue(ac, body: 'hi cy');
      await _until(
        () => (app.read(sendQueueProvider)[ac] ?? const []).isEmpty,
        'the queue to drain',
      );
      final row = (await _row(cy, m.id))!;
      expect(row['body'], 'hi cy');
      expect(row['ciphertext'], isNull);
    });
  });

  group('SupabaseEncryptedMessageRepository', () {
    late EncryptedMessageRepository asAna, asBen, asDan;
    setUpAll(() {
      asAna = SupabaseEncryptedMessageRepository(ana);
      asBen = SupabaseEncryptedMessageRepository(ben);
      asDan = SupabaseEncryptedMessageRepository(dan);
    });

    test('send stores the placeholder row; a retry with the SAME ciphertext '
        'is Ok (the stored row)', () async {
      final id = _newId();
      final first = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'QUFBQQ',
        olmType: 0,
      );
      final row = switch (first) {
        Ok(:final value) => value,
        Err(:final failure) => fail('send: $failure'),
      };
      expect(
        (row.id, row.body, row.senderId),
        (id, lockedBodyPlaceholder, _id(ana)),
      );
      final again = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'QUFBQQ',
        olmType: 0,
      );
      expect(switch (again) {
        Ok(:final value) => value.id,
        Err(:final failure) => failure,
      }, id);
    });

    test('a retry with ANOTHER ciphertext: Denied', () async {
      final id = _newId();
      await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'Q1Qx',
        olmType: 0,
      );
      final r = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'Q1Qy',
        olmType: 0,
      );
      expect(_failure(r), isA<DeniedFailure>());
    });

    test('the id stored in ANOTHER chat of ana: Denied', () async {
      final id = _newId();
      await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'Q1Qz',
        olmType: 0,
      );
      final r = await asAna.send(
        id: id,
        conversationId: ad,
        ciphertext: 'Q1Qz',
        olmType: 0,
      );
      expect(_failure(r), isA<DeniedFailure>());
    });

    test('the id stored by ANOTHER sender in the same chat: Denied', () async {
      final id = _newId();
      expect(
        await asBen.send(
          id: id,
          conversationId: ab,
          ciphertext: 'QkVO',
          olmType: 0,
        ),
        isA<Ok<Message>>(),
      );
      final r = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'QkVO',
        olmType: 0,
      );
      expect(_failure(r), isA<DeniedFailure>());
    });

    test('the id stored where the caller cannot see it: Denied', () async {
      final id = _newId();
      await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'SElE',
        olmType: 0,
      );
      final r = await asDan.send(
        id: id,
        conversationId: db,
        ciphertext: 'SElE',
        olmType: 0,
      );
      expect(_failure(r), isA<DeniedFailure>());
    });

    test('a reply: the retry must name the same reply target', () async {
      final target = _newId();
      await asBen.send(
        id: target,
        conversationId: ab,
        ciphertext: 'VEdU',
        olmType: 0,
      );
      final other = _newId();
      await asBen.send(
        id: other,
        conversationId: ab,
        ciphertext: 'T1RI',
        olmType: 0,
      );
      final id = _newId();
      final first = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'UkVQ',
        olmType: 1,
        replyTo: target,
      );
      expect(switch (first) {
        Ok(:final value) => value.replyTo,
        Err(:final failure) => failure,
      }, target);
      final wrong = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'UkVQ',
        olmType: 1,
        replyTo: other,
      );
      expect(_failure(wrong), isA<DeniedFailure>());
      final same = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'UkVQ',
        olmType: 1,
        replyTo: target,
      );
      expect(same, isA<Ok<Message>>());
    });

    test('a forward is stored marked forwarded', () async {
      final id = _newId();
      final r = await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'RldE',
        olmType: 1,
        forwarded: true,
      );
      expect(switch (r) {
        Ok(:final value) => value.forwarded,
        Err(:final failure) => failure,
      }, isTrue);
      final row = await ana
          .from('messages')
          .select('forwarded')
          .eq('id', id)
          .single();
      expect(row['forwarded'], isTrue);
    });

    test('a chat with a member without keys (42501): Denied', () async {
      final r = await asAna.send(
        id: _newId(),
        conversationId: ac,
        ciphertext: 'Tk9L',
        olmType: 0,
      );
      expect(_failure(r), isA<DeniedFailure>());
    });

    test('offline: a retryable NetworkFailure', () async {
      final dead = await deadButSignedIn(ana);
      addTearDown(dead.dispose);
      final r = await SupabaseEncryptedMessageRepository(
        dead,
      ).send(id: _newId(), conversationId: ab, ciphertext: 'T0ZG', olmType: 0);
      final f = _failure(r);
      expect(f, isA<NetworkFailure>());
      expect((f! as NetworkFailure).retryable, isTrue);
    });

    test('edit: ana replaces her ciphertext; ben cannot edit hers', () async {
      final id = _newId();
      await asAna.send(
        id: id,
        conversationId: ab,
        ciphertext: 'RURJ',
        olmType: 0,
      );
      final r = await asAna.edit(id: id, ciphertext: 'RURJMg', olmType: 1);
      final edited = switch (r) {
        Ok(:final value) => value,
        Err(:final failure) => fail('edit: $failure'),
      };
      expect(edited.body, lockedBodyPlaceholder);
      expect(edited.editedAt, isNotNull);
      final row = (await _row(ana, id))!;
      expect((row['ciphertext'], row['olm_type']), ('RURJMg', 1));
      expect(
        _failure(await asBen.edit(id: id, ciphertext: 'QkJC', olmType: 1)),
        isA<DeniedFailure>(),
      );
    });
  });
}
