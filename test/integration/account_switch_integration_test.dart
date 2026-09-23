@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Two accounts, one after the other, on ONE client — one phone.
///
/// The widget tests replay the owner's report over fakes that share a
/// session. This checks the assumption those fakes encode: that on a real
/// client, after one member signs out and another signs in, the providers
/// `main.dart` wires re-read as the new member and the server answers for
/// them. Every repository is the production one over the same client, and
/// the session controller runs over the real [SupabaseAuthRepository]. Only
/// the Google sheet is replaced — there is no Google locally — by a password
/// sign-in on the same client, which fires the same auth-state change.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts (jude, kara, lena): signing in claims the active device.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<void> _passwordSignIn(SupabaseClient client, String email) async {
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
}

/// A member on their own phone, for the fixtures.
Future<SupabaseClient> elsewhere(String email) async {
  final client = _client();
  await _passwordSignIn(client, email);
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

/// The production repository with the Google sheet swapped for a password
/// sign-in to [next]. Everything else — session, change stream, activation,
/// member lookup, sign-out — is [SupabaseAuthRepository] itself.
class PasswordAuth implements AuthRepository {
  PasswordAuth(this.client)
    : real = SupabaseAuthRepository(
        client,
        GoogleSignIn.instance,
        googleWebClientId: 'unused-locally',
      );
  final SupabaseClient client;
  final SupabaseAuthRepository real;
  String? next;

  @override
  Future<Result<void>> signInWithGoogle() async {
    try {
      await client.auth.signInWithPassword(email: next!, password: _password);
      return const Ok(null);
    } on AuthException catch (e) {
      return Err(ProviderFailure(e.message));
    }
  }

  @override
  bool get hasSession => real.hasSession;
  @override
  Stream<bool> get signedInChanges => real.signedInChanges;
  @override
  Future<Result<bool>> activateSession() => real.activateSession();
  @override
  Future<Result<Member>> currentMember() => real.currentMember();
  @override
  Future<void> signOut() => real.signOut();
}

/// Polls until [done]; there is no callback for "the server answered".
Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final stamp = DateTime.now().microsecondsSinceEpoch;
  late String judeId, karaId, lenaId;
  late String judeWithLena, karaWithLena;
  SupabaseClient? lena;
  SupabaseClient? phone;
  late PasswordAuth auth;
  late ProviderContainer c;
  var home = false;

  setUpAll(() async {
    // jude and kara each have a conversation with lena the other is not in.
    for (final (email, set) in [
      ('jude@integration.test', (String id) => judeId = id),
      ('kara@integration.test', (String id) => karaId = id),
    ]) {
      final other = await elsewhere(email);
      set(other.auth.currentUser!.id);
      await other.dispose();
    }
    lena = await elsewhere('lena@integration.test');
    lenaId = lena!.auth.currentUser!.id;
    final fromLena = SupabaseChatRepository(lena!);
    judeWithLena =
        (await fromLena.startDirectConversation(judeId) as Ok<String>).value;
    karaWithLena =
        (await fromLena.startDirectConversation(karaId) as Ok<String>).value;
    for (final id in [judeWithLena, karaWithLena]) {
      expect(
        await fromLena.send(conversationId: id, body: 'lena $stamp'),
        isA<Ok<Object?>>(),
      );
    }

    // The phone: one client, every provider wired as main.dart wires it.
    phone = _client();
    auth = PasswordAuth(phone!);
    c = ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'unused-locally',
          ),
        ),
        authRepositoryProvider.overrideWithValue(auth),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(phone!),
        ),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(phone!),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(phone!),
        ),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    await until(
      () => c.read(sessionControllerProvider).value is SignedOut,
      'a fresh phone to start signed out',
    );
  });

  tearDownAll(() async {
    c.dispose();
    await phone?.dispose();
    await lena?.dispose();
  });

  Future<void> signInAs(String email, String id) async {
    auth.next = email;
    await c.read(sessionControllerProvider.notifier).signIn();
    await until(() => c.read(currentUserIdProvider) == id, 'Allowed($email)');
    if (!home) {
      // Home mounts once someone is allowed, and from then on keeps these
      // alive, exactly as the app does: they are never read signed out.
      home = true;
      c.listen(ownProfileProvider, (_, _) {});
      c.listen(membersProvider, (_, _) {});
      c.listen(conversationListProvider, (_, _) {});
    }
    // Let the rebuilds start before waiting for them to finish: a provider
    // that was never invalidated is not loading, and is read as it stands.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await until(
      () =>
          !c.read(membersProvider).isLoading &&
          !c.read(conversationListProvider).isLoading &&
          !c.read(ownProfileProvider).isLoading,
      'the providers to settle',
    );
  }

  Future<void> signOut() async {
    await c.read(sessionControllerProvider.notifier).signOut();
    await until(() => c.read(currentUserIdProvider) == null, 'signed out');
  }

  Set<String> members() => {
    for (final m in c.read(membersProvider).requireValue) m.userId,
  };
  Set<String> listed() => {
    for (final x in c.read(conversationListProvider).requireValue) x.id,
  };

  test('the second account on the phone gets its own members and '
      'conversations, and the first gets hers back', () async {
    await signInAs('jude@integration.test', judeId);
    expect(members(), containsAll([karaId, lenaId]));
    expect(members(), isNot(contains(judeId)));
    expect(listed(), contains(judeWithLena));
    expect(listed(), isNot(contains(karaWithLena)));

    await signOut();
    await signInAs('kara@integration.test', karaId);

    expect(
      members(),
      containsAll([judeId, lenaId]),
      reason: 'the picker must offer the account that just signed out',
    );
    expect(
      members(),
      isNot(contains(karaId)),
      reason: 'the picker offers kara to herself: it is still jude\'s list',
    );
    expect(listed(), contains(karaWithLena));
    expect(
      listed(),
      isNot(contains(judeWithLena)),
      reason: 'jude\'s conversation is on kara\'s list',
    );
    expect(c.read(ownProfileProvider).requireValue.userId, karaId);

    await signOut();
    await signInAs('jude@integration.test', judeId);
    expect(members(), isNot(contains(judeId)));
    expect(members(), contains(karaId));
    expect(listed(), contains(judeWithLena));
    expect(listed(), isNot(contains(karaWithLena)));
    expect(c.read(ownProfileProvider).requireValue.userId, judeId);
  });
}
