@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/crypto/rust/api/olm.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/supabase_key_directory.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/drift_stores.dart';
import '../support/key_directory_fakes.dart';
import '../support/reach.dart';

/// The key directory through the real stack (Private Chats step 3):
/// KeyDirectoryController wired as main.dart wires it -- SupabaseKeyDirectory
/// over a client signed in to the local Supabase, the real OlmKeyEngine
/// (vodozemac through FRB), DriftOlmPickleStore over the real encrypted
/// on-phone store -- with only the platform secure storage (the pickle key)
/// and the session faked.
///
/// What only the real stack shows: that a key made by the engine passes the
/// server's format checks; that another reachable member claims it, verifies
/// the device signature and opens a working Olm session with it; that two
/// claims at the same moment get different keys; that a member who cannot
/// reach the target gets DeniedFailure; that the pickle survives a restart in
/// the real store and the restart re-publishes the same identity.
///
/// Needs the Rust library built (cargo build --release) and a freshly reset
/// stack. Fixtures (supabase/seed.sql): ana publishes, ben finds ana by tag
/// and claims; cy is allowlisted and active but cannot reach ana.
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

Member _member(SupabaseClient c) =>
    Member(userId: c.auth.currentUser!.id, displayName: 'kd');

/// A container as main.dart builds it for [client]'s member, store in [dir].
ProviderContainer _wired(SupabaseClient client, Directory dir) {
  final c = ProviderContainer(
    overrides: [
      sessionControllerProvider.overrideWith(
        () => DrivenSession(Allowed(_member(client))),
      ),
      ...driftStoreOverrides(dir, 'ab' * 32),
      olmPickleStoreProvider.overrideWith(
        (ref) => DriftOlmPickleStore(
          ref.watch(messageStoreProvider) as DriftMessageStore,
        ),
      ),
      pickleKeyStoreProvider.overrideWithValue(FakePickleKeys()),
      keyEngineProvider.overrideWithValue(OlmKeyEngine()),
      keyDirectoryProvider.overrideWithValue(SupabaseKeyDirectory(client)),
    ],
  );
  c.listen(keyDirectoryControllerProvider, (_, _) {});
  return c;
}

/// The state once the run for the (settled) session is over: not idle
/// waiting for the session, not publishing. The last state after 30 s.
Future<KeyDirectoryState> _settled(ProviderContainer c) async {
  await c.read(sessionControllerProvider.future);
  final end = DateTime.now().add(const Duration(seconds: 30));
  var s = c.read(keyDirectoryControllerProvider);
  while (DateTime.now().isBefore(end)) {
    s = c.read(keyDirectoryControllerProvider);
    if (s is! KeysPublishing && s is! KeysIdle) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return s;
}

void main() {
  late SupabaseClient ana, ben, cy;
  late Directory anaDir, benDir;

  setUpAll(() async {
    ana = await _signedIn('kd-ana@mail.test');
    ben = await _signedIn('kd-ben@mail.test');
    cy = await _signedIn('kd-cy@mail.test');
    await findByTag(ben, [ana]);
    anaDir = await Directory.systemTemp.createTemp('kd-ana');
    benDir = await Directory.systemTemp.createTemp('kd-ben');
  });

  tearDownAll(() async {
    for (final c in [ana, ben, cy]) {
      await c.dispose();
    }
    await anaDir.delete(recursive: true);
    await benDir.delete(recursive: true);
  });

  test('ana publishes; ben claims, verifies and opens a working session; '
      'cy is refused; a restart keeps the identity', () async {
    final anaId = ana.auth.currentUser!.id;
    final anaKeys = _wired(ana, anaDir);
    final first = await _settled(anaKeys);
    expect(first, isA<KeysReady>());
    expect((first as KeysReady).freeOneTimeKeys, 50);

    final status = await SupabaseKeyDirectory(ana).status();
    final row = (status as Ok<PublishedStatus?>).value!;
    expect(row.oneTimeKeys, 50);
    expect(row.hasFallback, isTrue);
    expect(row.fallbackUsed, isFalse);

    final benKeys = _wired(ben, benDir);
    await _settled(benKeys);
    final claimed = await benKeys
        .read(keyDirectoryControllerProvider.notifier)
        .claimVerified(anaId);
    final keys = (claimed as Ok<ClaimedKeys?>).value!;
    expect(keys.identityKey, row.identityKey);
    expect(keys.signingKey, row.signingKey);
    expect(keys.isFallback, isFalse);

    // The claimed key is real: ben opens a session, ana's saved account
    // (read back from the real store) accepts it.
    final benAccount = OlmAccount();
    final out = benAccount.createOutboundSession(
      theirIdentityKey: keys.identityKey,
      theirOneTimeKey: keys.oneTimeKey,
    );
    final msg = out.encrypt(plaintext: utf8.encode('merhaba'));
    final pickle = await anaKeys.read(olmPickleStoreProvider)!.load();
    expect(pickle, isNotNull);
    final anaAccount = OlmAccount.fromPickle(
      pickle: pickle!,
      key: FakePickleKeys.key,
    );
    expect(anaAccount.identityKey(), keys.identityKey);
    final inbound = anaAccount.createInboundSession(
      theirIdentityKey: benAccount.identityKey(),
      message: msg,
    );
    expect(utf8.decode(inbound.plaintext), 'merhaba');

    // Two claims at the same moment never get the same key.
    final both = await Future.wait([
      SupabaseKeyDirectory(ben).claim(anaId),
      SupabaseKeyDirectory(ben).claim(anaId),
    ]);
    final two = both.map((r) => (r as Ok<ClaimedKeys?>).value!).toList();
    expect(two.map((k) => k.isFallback), [false, false]);
    expect({
      two[0].oneTimeKey,
      two[1].oneTimeKey,
      keys.oneTimeKey,
    }, hasLength(3));

    // cy cannot reach ana: the same refusal as any other gate.
    final refused = await SupabaseKeyDirectory(cy).claim(anaId);
    expect((refused as Err<ClaimedKeys?>).failure, isA<DeniedFailure>());

    // Restart: a new container over the same store restores the pickle and
    // re-publishes the same identity; the server counts only free keys.
    anaKeys.dispose();
    final again = _wired(ana, anaDir);
    final second = await _settled(again);
    expect(second, isA<KeysReady>());
    final after =
        (await SupabaseKeyDirectory(ana).status()) as Ok<PublishedStatus?>;
    expect(after.value!.identityKey, row.identityKey);
    expect(after.value!.oneTimeKeys, 47);

    // The store's clear() takes the pickle with it.
    await (again.read(messageStoreProvider) as DriftMessageStore).clear();
    expect(await again.read(olmPickleStoreProvider)!.load(), isNull);
    again.dispose();

    // Same session, pickle gone (store reset): fail closed, no new identity.
    final lost = _wired(ana, anaDir);
    expect(await _settled(lost), isA<KeysIdentityLost>());
    lost.dispose();
    final still =
        (await SupabaseKeyDirectory(ana).status()) as Ok<PublishedStatus?>;
    expect(still.value!.identityKey, row.identityKey);
    expect(still.value!.sameSession, isTrue);

    // Sign out and back in (a new session, the store starts empty): a new
    // account is made and published, and the old phone's keys are gone.
    await ana.auth.signOut();
    await ana.auth.signInWithPassword(email: 'kd-ana@mail.test', password: _pw);
    expect(await ana.rpc('activate_session'), isTrue);
    final before =
        (await SupabaseKeyDirectory(ana).status()) as Ok<PublishedStatus?>;
    expect(
      before.value!.sameSession,
      isFalse,
      reason: 'the row is the old session\'s',
    );
    final freshDir = await Directory.systemTemp.createTemp('kd-ana2');
    final fresh = _wired(ana, freshDir);
    final third = await _settled(fresh);
    expect(third, isA<KeysReady>());
    expect(
      (third as KeysReady).freeOneTimeKeys,
      50,
      reason: 'the 47 old free keys were wiped, not added to',
    );
    final now =
        (await SupabaseKeyDirectory(ana).status()) as Ok<PublishedStatus?>;
    expect(now.value!.identityKey, isNot(row.identityKey));
    expect(now.value!.sameSession, isTrue);
    expect(now.value!.oneTimeKeys, 50);
    final newClaim = await benKeys
        .read(keyDirectoryControllerProvider.notifier)
        .claimVerified(anaId);
    final newKeys = (newClaim as Ok<ClaimedKeys?>).value!;
    expect(newKeys.identityKey, now.value!.identityKey);
    expect(newKeys.isFallback, isFalse);
    expect([
      keys.oneTimeKey,
      two[0].oneTimeKey,
      two[1].oneTimeKey,
    ], isNot(contains(newKeys.oneTimeKey)));
    fresh.dispose();
    await freshDir.delete(recursive: true);
    benKeys.dispose();
  });
}
