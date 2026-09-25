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
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/supabase_push_registry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/service_key.dart';

/// Which kind of push a phone is sent, decided by how it registered.
///
/// From 0.12 the app shows pushes itself and wants data only; a 0.11 build
/// cannot show a data-only push and must keep getting a regular one.
/// Updates are never forced, so both live side by side, and the delivery
/// list says per device which it is (`shows_itself`).
///
/// The pgTAP suite proves the SQL. This proves the two app-side callers of
/// it over the real stack: the RPC exactly as a 0.11 build sends it (two
/// named parameters, no flag), and this build's registration path as
/// `main.dart` mounts it -- PushRegistration over the production
/// [SupabasePushRegistry], with the session controller over the real
/// [SupabaseAuthRepository]. Only the Firebase side is a fake (there is no
/// Firebase locally): it hands over the phone's token. What each phone would
/// be sent is read back from public.push_targets, the function the sender
/// calls, with the service key.
///
/// Requires `docker compose run --rm supabase start` and
/// SUPABASE_TEST_SERVICE_KEY (test/support/service_key.dart). Uses its own
/// seeded accounts (nell, oren): signing in claims the active device.
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

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  return client;
}

/// The production auth repository; the phone is already signed in, so the
/// Google sheet is never reached.
class _SignedInAuth implements AuthRepository {
  _SignedInAuth(SupabaseClient client)
    : real = SupabaseAuthRepository(
        client,
        GoogleSignIn.instance,
        googleWebClientId: 'unused-locally',
      );
  final SupabaseAuthRepository real;

  @override
  Future<Result<void>> signInWithGoogle() async =>
      const Err(ProviderFailure('no Google locally'));
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

Future<void> _until(bool Function() done, String what) async {
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
  // One handset, one token, across the update.
  final orenToken = 'itest-display-oren-$stamp';
  late SupabaseClient service;
  late SupabaseClient nell;
  late String orenId;
  late String conversation;

  setUpAll(() async {
    service = SupabaseClient(_url, serviceKey());
    final oren = await _signedIn('oren@integration.test');
    orenId = oren.auth.currentUser!.id;
    await oren.dispose();
    nell = await _signedIn('nell@integration.test');
    expect(await nell.rpc('activate_session'), isTrue);
    final started = await SupabaseChatRepository(nell)
        .startDirectConversation(orenId);
    conversation = (started as Ok<String>).value;
  });

  tearDownAll(() async {
    await nell.dispose();
    await service.dispose();
  });

  /// nell writes to oren; what the sender would be told to deliver to him.
  Future<List<Map<String, dynamic>>> deliveryToOren() async {
    final row = await nell
        .from('messages')
        .insert({
          'conversation_id': conversation,
          'sender_id': nell.auth.currentUser!.id,
          'body': 'display $stamp',
        })
        .select('id')
        .single();
    final targets = await service.rpc(
      'push_targets',
      params: {'message_id': row['id']},
    );
    return [
      for (final t in targets as List)
        if (t['user_id'] == orenId) Map<String, dynamic>.from(t as Map),
    ];
  }

  test('a 0.11 build registers the way it always has and stays on regular '
      'notifications', () async {
    final phone = await _signedIn('oren@integration.test');
    addTearDown(phone.dispose);
    expect(await phone.rpc('activate_session'), isTrue);
    // Verbatim the call a 0.11 build makes.
    await phone.rpc(
      'register_device_token',
      params: {'device_token': orenToken, 'device_platform': 'android'},
    );

    final targets = await deliveryToOren();
    expect(targets, hasLength(1), reason: '$targets');
    expect(targets.single['token'], orenToken);
    expect(
      targets.single['shows_itself'],
      isFalse,
      reason:
          'a phone that cannot show a data-only push must be sent a '
          'regular notification',
    );
  });

  test('updating the app switches the same phone over on its next start, '
      'through the registration path main.dart mounts', () async {
    final phone = await _signedIn('oren@integration.test');
    addTearDown(phone.dispose);
    final source = PushSourceFake(token: orenToken);
    final c = ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'unused-locally',
          ),
        ),
        authRepositoryProvider.overrideWithValue(_SignedInAuth(phone)),
        pushSourceProvider.overrideWithValue(source),
        pushRegistryProvider.overrideWithValue(SupabasePushRegistry(phone)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(pushRegistrationProvider, (_, _) {});
    await _until(
      () => c.read(currentUserIdProvider) == orenId,
      'oren to be signed in on the updated app',
    );
    await _until(
      () => c.read(pushRegistrationProvider) == orenToken,
      'the updated app to register its token',
    );

    final targets = await deliveryToOren();
    expect(targets, hasLength(1), reason: '$targets');
    expect(targets.single['token'], orenToken, reason: 'the same handset');
    expect(
      targets.single['shows_itself'],
      isTrue,
      reason: 'this build shows pushes itself: it must be sent data only',
    );
  });
}
