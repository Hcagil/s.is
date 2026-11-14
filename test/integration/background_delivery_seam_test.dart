/// Background delivery integration test against a real local Supabase.
///
/// Uses the same test setup as delivery_marks_repository_test.dart but
/// focuses on the background delivery RPC and its interaction with
/// flutter_secure_storage.

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/notifications/data/background_delivery.dart';
import 'package:sis/core/failure.dart';

import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/secure_channel_fake.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _bgUrl = String.fromEnvironment('SUPABASE_URL');
const _bgKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<SupabaseClient> _signedIn(String email) async {
  await setLocalTestPassword(_url, email, localTestPassword);
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
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

String sessionOf(SupabaseClient c, {int? expiresAt}) => jsonEncode({
  'access_token': c.auth.currentSession!.accessToken,
  'expires_at': expiresAt ?? c.auth.currentSession!.expiresAt,
  'user': {'id': c.auth.currentUser!.id},
});

Future<Message> _send(SupabaseChatRepository repo, String conversation) async {
  final r = await repo.send(
    id: randomMessageId(),
    conversationId: conversation,
    body: _stamp('d'),
  );
  expect(r, isA<Ok<Message>>(), reason: 'send failed: $r');
  return (r as Ok<Message>).value;
}

Future<bool> _delivered(
  SupabaseChatRepository repo,
  String conversation,
  Message m,
  String memberId,
) async {
  final r = await repo.readMarks(conversation);
  expect(r, isA<Ok<List<ReadMark>>>(), reason: 'readMarks failed: $r');
  final marks = (r as Ok<List<ReadMark>>).value;
  return marks
      .singleWhere((x) => x.userId == memberId)
      .hasDelivered(m.createdAt);
}

void main() {
  late SupabaseClient avaClient, benClient, cyClient;
  late SupabaseChatRepository ava;
  late String benId;
  late String direct;
  late SecureChannelFake secure;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    avaClient = await _signedIn('bd-ava@mail.test');
    benClient = await _signedIn('bd-ben@mail.test');
    cyClient = await _signedIn('bd-cy@mail.test');
    ava = SupabaseChatRepository(avaClient);
    benId = benClient.auth.currentUser!.id;
    await findByTag(avaClient, [benClient, cyClient]);
    direct = (await ava.startDirectConversation(
      benClient.auth.currentUser!.id,
    ) as Ok<String>).value;
  });

  tearDownAll(() async {
    await avaClient.dispose();
    await benClient.dispose();
    await cyClient.dispose();
  });

  setUp(() {
    secure = SecureChannelFake()..install();
  });

  group('SupabaseBackgroundDelivery.markDelivered', () {
    test(
      'a member token in the saved session advances the member delivery mark',
      () async {
        if (_bgUrl.isEmpty || _bgKey.isEmpty) {
          markTestSkipped(
            'needs --dart-define=SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY',
          );
          return;
        }
        final m = await _send(ava, direct);
        expect(await _delivered(ava, direct, m, benId), isFalse);
        secure.put(null, 'sis.supabase.session', sessionOf(benClient));
        await const SupabaseBackgroundDelivery().markDelivered(direct);
        expect(await _delivered(ava, direct, m, benId), isTrue);
        expect(secure.changes, isEmpty);
      },
    );

    test('a token expiring within 30 s is not used', () async {
      if (_bgUrl.isEmpty || _bgKey.isEmpty) {
        markTestSkipped(
          'needs --dart-define=SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY',
        );
        return;
      }
      final m = await _send(ava, direct);
      final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10;
      secure.put(
        null,
        'sis.supabase.session',
        sessionOf(benClient, expiresAt: soon),
      );
      await const SupabaseBackgroundDelivery().markDelivered(direct);
      expect(await _delivered(ava, direct, m, benId), isFalse);
      secure.put(null, 'sis.supabase.session', sessionOf(benClient));
      await const SupabaseBackgroundDelivery().markDelivered(direct);
      expect(await _delivered(ava, direct, m, benId), isTrue);
    });

    test('a non-member is refused by the server and nothing throws', () async {
      if (_bgUrl.isEmpty || _bgKey.isEmpty) {
        markTestSkipped(
          'needs --dart-define=SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY',
        );
        return;
      }
      await expectLater(
        cyClient.rpc('mark_delivered', params: {'conversation': direct}),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      final m = await _send(ava, direct);
      secure.put(null, 'sis.supabase.session', sessionOf(cyClient));
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered(direct),
        completes,
      );
      expect(await _delivered(ava, direct, m, benId), isFalse);
      expect(secure.changes, isEmpty);
    });

    test('no saved session: completes, nothing advances', () async {
      if (_bgUrl.isEmpty || _bgKey.isEmpty) {
        markTestSkipped(
          'needs --dart-define=SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY',
        );
        return;
      }
      final m = await _send(ava, direct);
      await expectLater(
        const SupabaseBackgroundDelivery().markDelivered(direct),
        completes,
      );
      expect(await _delivered(ava, direct, m, benId), isFalse);
    });
  });
}
