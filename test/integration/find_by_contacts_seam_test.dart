@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_contacts_repository.dart';
import 'package:sis/features/chat/domain/contacts_repository.dart';
import 'package:sis/features/chat/domain/phone_book.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/contact_fakes.dart';
import '../support/fakes.dart';

/// Find people from your contacts through the real stack (step 16):
/// [SupabaseContactsRepository] over clients signed in to a running local
/// Supabase, and FindFromContactsController wired the way main.dart wires it
/// (the contacts repository is the Supabase one; only the phone book and the
/// local disclosure flag, both device boundaries, are fakes).
///
/// What only the real stack can show: that the phone's hash of a contact's
/// email equals the server's hash of the allowlist email; that RLMT1 arrives
/// as SearchLimitFailure and bad input as another failure; that no email
/// comes back; that the controller ends limited when the server says so.
///
/// Needs a freshly reset stack (`supabase db reset`), as CI has: cem spends
/// the hourly budget, asli uses two of hers.
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

class _As extends SessionController {
  _As(this.id);
  final String id;
  @override
  Future<SessionState> build() async =>
      Allowed(Member(userId: id, displayName: id));
}

/// The contract's hash, computed here rather than by the code under test.
String _hash(String email) =>
    sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

T _ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => fail('expected Ok, got ${failure.message}'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient asli, bora, cem;
  String id(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    asli = await _signedIn('fc-asli@mail.test');
    bora = await _signedIn('fc-bora@mail.test');
    cem = await _signedIn('fc-cem@mail.test');
  });

  tearDownAll(() async {
    for (final c in [asli, bora, cem]) {
      await c.dispose();
    }
  });

  Future<FindContactsState> opened(
    SupabaseClient client,
    List<PhoneBookPerson> persons,
  ) async {
    final c = ProviderContainer.test(
      overrides: [
        contactsRepositoryProvider.overrideWithValue(
          SupabaseContactsRepository(client),
        ),
        phoneBookProvider.overrideWithValue(FakePhoneBook(persons: persons)),
        contactsDisclosureStoreProvider.overrideWithValue(
          FakeDisclosureStore(isAccepted: true),
        ),
        sessionControllerProvider.overrideWith(() => _As(id(client))),
      ],
    );
    addTearDown(c.dispose);
    await settled(c);
    c.listen(findFromContactsControllerProvider, (_, _) {});
    return c.read(findFromContactsControllerProvider.future);
  }

  test('the server finds a member by the phone\'s hash; no email comes '
      'back; bad input is a failure, not the limit', () async {
    final repo = SupabaseContactsRepository(asli);

    final bad = await repo.findByContacts([
      _hash('fc-bora@mail.test').toUpperCase(),
    ]);
    expect(bad, isA<Err<List<ContactMatch>>>());
    expect(
      (bad as Err<List<ContactMatch>>).failure,
      isNot(isA<SearchLimitFailure>()),
    );

    final found = _ok(
      await repo.findByContacts([
        hashContactEmail('  FC-Bora@Mail.test '),
        _hash('nobody@mail.test'),
      ]),
    );
    expect(found, hasLength(1));
    expect(found.single.member.userId, id(bora));
    expect(found.single.hash, _hash('fc-bora@mail.test'));
    expect(found.single.member.email, isNull, reason: 'never an email');
  });

  test('a member never finds herself', () async {
    final found = _ok(
      await SupabaseContactsRepository(bora)
          .findByContacts([_hash('fc-bora@mail.test')]),
    );
    expect(found, isEmpty);
  });

  test('a signed-out client is refused', () async {
    final anon = SupabaseClient(_url, _key);
    addTearDown(anon.dispose);
    final r = await SupabaseContactsRepository(anon)
        .findByContacts([_hash('fc-bora@mail.test')]);
    expect(r, isA<Err<List<ContactMatch>>>());
  });

  test(
    'the controller, wired as main.dart wires it, shows who is on SIS',
    () async {
      final s = await opened(asli, const [
        PhoneBookPerson(
          id: '1',
          name: 'Bora B',
          emails: [' FC-Bora@Mail.test'],
        ),
        PhoneBookPerson(id: '2', name: 'Nobody', emails: ['nobody@mail.test']),
        PhoneBookPerson(id: '3', name: 'No Mail', emails: []),
      ]);
      expect(s, isA<FindResult>());
      final r = s as FindResult;
      expect(r.limited, isFalse);
      expect(r.onSis.map((f) => f.member.userId), [id(bora)]);
      expect(r.onSis.single.name, 'Bora B');
      expect(r.notOnSis, containsAll(['Nobody', 'No Mail']));
    },
  );

  test('the 4th call in an hour is SearchLimitFailure, and the controller '
      'shows limited', () async {
    final repo = SupabaseContactsRepository(cem);
    for (var i = 0; i < 3; i++) {
      _ok(await repo.findByContacts([_hash('nobody$i@mail.test')]));
    }
    final fourth = await repo.findByContacts([_hash('fc-bora@mail.test')]);
    expect(fourth, isA<Err<List<ContactMatch>>>());
    expect(
      (fourth as Err<List<ContactMatch>>).failure,
      isA<SearchLimitFailure>(),
    );

    final s = await opened(cem, const [
      PhoneBookPerson(id: '1', name: 'Bora B', emails: ['fc-bora@mail.test']),
    ]);
    expect(s, isA<FindResult>());
    expect((s as FindResult).limited, isTrue);
    expect(s.onSis, isEmpty);
  });
}
