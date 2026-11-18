@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_mark_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'int-pw';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await setLocalTestPassword(_url, email, _password);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient grace;
  late SupabaseClient ivy;
  late SupabaseClient frank;
  late String convId;

  Future<void> clearMarked() async {
    final svc = SupabaseClient(_url, serviceKey());
    await svc.from('chat_marked_unread').delete().eq('conversation_id', convId);
    await svc.dispose();
  }

  setUpAll(() async {
    grace = await _signedIn('it-grace@mail.test');
    ivy = await _signedIn('it-ivy@mail.test');
    frank = await _signedIn('it-frank@mail.test');

    await findByTag(grace, [ivy]);

    convId = _ok(
      await SupabaseChatRepository(grace)
          .startDirectConversation(ivy.auth.currentUser!.id),
      'start the grace-ivy chat',
    );
    await clearMarked();
  });

  setUp(() async => clearMarked());

  tearDownAll(() async {
    await clearMarked();
    await grace.dispose();
    await ivy.dispose();
    await frank.dispose();
  });

  test('a member marks a chat unread: Ok and one row for her', () async {
    final r = await SupabaseChatMarkRepository(grace).markChatUnread(convId);
    expect(r, isA<Ok<void>>());

    final svc = SupabaseClient(_url, serviceKey());
    final rows = await svc
        .from('chat_marked_unread')
        .select()
        .eq('conversation_id', convId);
    await svc.dispose();

    expect(rows.length, 1);
    expect(rows.first['user_id'], grace.auth.currentUser!.id);
  });

  test('marking twice leaves one row', () async {
    final r1 = await SupabaseChatMarkRepository(grace).markChatUnread(convId);
    final r2 = await SupabaseChatMarkRepository(grace).markChatUnread(convId);
    expect(r1, isA<Ok<void>>());
    expect(r2, isA<Ok<void>>());

    final svc = SupabaseClient(_url, serviceKey());
    final rows = await svc
        .from('chat_marked_unread')
        .select()
        .eq('conversation_id', convId);
    await svc.dispose();

    expect(rows.length, 1);
  });

  test(
    'a non-member is refused with DeniedFailure and nothing is written',
    () async {
      final r = await SupabaseChatMarkRepository(frank).markChatUnread(convId);
      expect(r, isA<Err<void>>());
      expect((r as Err<void>).failure, isA<DeniedFailure>());

      final svc = SupabaseClient(_url, serviceKey());
      final rows = await svc
          .from('chat_marked_unread')
          .select()
          .eq('conversation_id', convId);
      await svc.dispose();

      expect(rows.isEmpty, isTrue);
    },
  );

  test('a signed-out client is refused with DeniedFailure', () async {
    final out = SupabaseClient(
      _url,
      _key,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    final r = await SupabaseChatMarkRepository(out).markChatUnread(convId);
    expect(r, isA<Err<void>>());
    expect((r as Err<void>).failure, isA<DeniedFailure>());

    final svc = SupabaseClient(_url, serviceKey());
    final rows = await svc
        .from('chat_marked_unread')
        .select()
        .eq('conversation_id', convId);
    await svc.dispose();

    expect(rows.isEmpty, isTrue);

    await out.dispose();
  });
}
