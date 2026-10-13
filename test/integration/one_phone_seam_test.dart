@Tags(['integration'])
library;

// One phone at a time (13b), against the running local Supabase: the real
// SupabaseAuthRepository, SupabasePushRegistry, FileLastSessionStore and
// SessionController on phone A; phone B is a second client of the SAME
// account (a second auth.sessions row, created later). Only the platform push
// source is a fake (there is no Firebase here).
//
// A signs in and registers its push token. B signs in, claims the session and
// registers its own token. Then A's resume check must see activate_session
// answer false and turn Replaced (not Denied), A's token must be gone from the
// server's delivery list, and A's sign-out must be LOCAL: B stays signed in
// and active.
//
// Uses its own seeded accounts (supabase/seed.sql): one-phone and
// one-phone-friend, which no other suite signs in to. Needs
// SUPABASE_TEST_SERVICE_KEY (test/support/service_key.dart).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/file_last_session_store.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/supabase_push_registry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart' show PushSourceFake;
import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _member = 'one-phone@integration.test';
const _friend = 'one-phone-friend@integration.test';

/// A new client signed in to [email]: a new auth.sessions row, i.e. a phone.
Future<SupabaseClient> _phone(String email, {bool activate = true}) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  if (activate) {
    expect(await client.rpc('activate_session'), isTrue, reason: email);
  }
  return client;
}

Future<void> _until(bool Function() ok, String what, [Object? seen]) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what: $seen');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String _token(String phone) =>
    'one-phone-$phone-${DateTime.now().microsecondsSinceEpoch}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient service, friend;
  late String conversation;
  final open = <SupabaseClient>[];
  final dirs = <Directory>[];

  setUpAll(() async {
    await setLocalTestPassword(_url, _member, localTestPassword);
    await setLocalTestPassword(_url, _friend, localTestPassword);
    service = SupabaseClient(_url, serviceKey());
    friend = await _phone(_friend);
  });

  tearDown(() async {
    for (final c in open) {
      await c.dispose();
    }
    open.clear();
    for (final d in dirs) {
      await d.delete(recursive: true);
    }
    dirs.clear();
  });

  tearDownAll(() async {
    await friend.dispose();
    await service.dispose();
  });

  /// The tokens the server would deliver the member's next push to.
  Future<Set<String>> targets(String memberId) async {
    final row = await friend
        .from('messages')
        .insert({
          'conversation_id': conversation,
          'sender_id': friend.auth.currentUser!.id,
          'body': 'one phone ${DateTime.now().microsecondsSinceEpoch}',
        })
        .select('id')
        .single();
    final list = await service.rpc(
      'push_targets',
      params: {'message_id': row['id']},
    );
    return {
      for (final t in list as List)
        if (t['user_id'] == memberId) t['token'] as String,
    };
  }

  test('signing in on phone B replaces phone A: A is Replaced, its push token '
      'is gone, and its sign-out leaves B signed in', () async {
    // Phone A, as the app runs it.
    final a = await _phone(_member, activate: false);
    open.add(a);
    final memberId = a.auth.currentUser!.id;
    final dir = await Directory.systemTemp.createTemp('sis-one-phone');
    dirs.add(dir);
    final tokenA = _token('a');
    final c = ProviderContainer(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'c',
          ),
        ),
        authRepositoryProvider.overrideWithValue(
          SupabaseAuthRepository(
            a,
            GoogleSignIn.instance,
            googleWebClientId: 'c',
          ),
        ),
        lastSessionStoreProvider.overrideWithValue(
          FileLastSessionStore(root: () async => dir),
        ),
        pushRegistryProvider.overrideWithValue(SupabasePushRegistry(a)),
        pushSourceProvider.overrideWithValue(PushSourceFake(token: tokenA)),
      ],
    );
    addTearDown(c.dispose);
    final states = <SessionState>[];
    c.listen(sessionControllerProvider, (_, next) {
      if (next.value case final v?) states.add(v);
    }, fireImmediately: true);
    SessionState? now() => c.read(sessionControllerProvider).value;
    await _until(
      () => now() is Allowed && (now()! as Allowed).confirmed,
      'A confirmed',
      states,
    );
    c.listen(pushRegistrationProvider, (_, _) {});
    await _until(
      () => c.read(pushRegistrationProvider) == tokenA,
      'A registered its token',
    );
    final marker = File('${dir.path}/last_session.json');
    await _until(marker.existsSync, 'A wrote its marker');

    await findByTag(friend, [a]);
    conversation = (await SupabaseChatRepository(
      friend,
    ).startDirectConversation(memberId) as Ok<String>).value;
    expect(await targets(memberId), {
      tokenA,
    }, reason: 'setup: A is not on the delivery list');

    // Phone B: same account, later session.
    final b = await _phone(_member);
    open.add(b);
    final tokenB = _token('b');
    expect(
      await SupabasePushRegistry(b).register(tokenB),
      isA<Ok<void>>(),
      reason: 'B could not register its token',
    );

    expect(
      await a.rpc('activate_session'),
      isFalse,
      reason: 'A still holds the session after B claimed it',
    );
    expect(await targets(memberId), {
      tokenB,
    }, reason: 'A\'s token is still delivered to, or B\'s is not');

    // A comes back to the foreground.
    c.read(sessionControllerProvider.notifier).recheck();
    await _until(() => now() is Replaced, 'A Replaced', states);
    expect(states.whereType<Denied>(), isEmpty, reason: '$states');
    await _until(() => !marker.existsSync(), 'A\'s marker wiped');

    // What the app does next on Replaced: forget the token, then sign out
    // locally.
    await c
        .read(pushRegistrationProvider.notifier)
        .forget()
        .timeout(const Duration(seconds: 5));
    await c.read(sessionControllerProvider.notifier).finishReplaced();
    expect(a.auth.currentSession, isNull, reason: 'A is still signed in');
    expect(now(), isA<Replaced>(), reason: 'the sign-out changed the screen');

    // LOCAL scope: B's session survived A's sign-out.
    expect(
      await b.rpc('activate_session'),
      isTrue,
      reason: 'A\'s sign-out ended B\'s session (global scope?)',
    );
    await b.auth.refreshSession();
    expect(b.auth.currentSession, isNotNull);
    expect(
      await b.rpc('activate_session'),
      isTrue,
      reason: 'B\'s refreshed session is no longer active',
    );
    expect(await targets(memberId), {tokenB});
  });
}
