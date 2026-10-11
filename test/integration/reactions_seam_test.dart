@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_reaction_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

/// The seam ReactionsController <-> SupabaseReactionRepository <-> the local
/// stack, wired as main.dart wires it (reactionRepositoryProvider overridden
/// with the Supabase repository): one member's react() reaches the other
/// member's open chat through Realtime, a clear removes it there, and a
/// server refusal (42501 for a non-member) comes back as DeniedFailure and
/// rolls the optimistic change back. Run with --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

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

class _As extends SessionController {
  _As(this.id);
  final String id;
  @override
  Future<SessionState> build() async =>
      Allowed(Member(userId: id, displayName: id));
}

Map<String, Set<(String, String?)>> _shape(ProviderContainer c) => {
  for (final e in (c.read(reactionsProvider).value ?? const {}).entries)
    if (e.value.isNotEmpty)
      e.key: {for (final x in e.value) (x.userId, x.emoji)},
};

Future<void> _until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late SupabaseClient priyaClient, quinlanClient, remyClient;
  late String priyaId, quinlanId, remyId;
  late SupabaseChatRepository priyaChat;
  late String club;

  Future<ProviderContainer> opened(SupabaseClient client, String id) async {
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(ChatFake()),
        reactionRepositoryProvider.overrideWithValue(
          SupabaseReactionRepository(client),
        ),
        sessionControllerProvider.overrideWith(() => _As(id)),
      ],
    );
    addTearDown(c.dispose);
    await settled(c);
    c.listen(reactionsProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(club);
    await c.read(reactionsProvider.future);
    // Let the join land and the reconcile settle.
    await Future<void>.delayed(const Duration(seconds: 1));
    return c;
  }

  setUpAll(() async {
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priyaId = priyaClient.auth.currentUser!.id;
    quinlanId = quinlanClient.auth.currentUser!.id;
    remyId = remyClient.auth.currentUser!.id;
    priyaChat = SupabaseChatRepository(priyaClient);
    final title = 'reactions seam ${DateTime.now().microsecondsSinceEpoch}';
    var r = await priyaChat.startGroupConversation(
      title: title,
      memberIds: [quinlanId],
    );
    if (r is Err<String>) {
      // Reach only when missing: find_by_tag is rate limited.
      await findByTag(priyaClient, [quinlanClient]);
      r = await priyaChat.startGroupConversation(
        title: title,
        memberIds: [quinlanId],
      );
    }
    club = (r as Ok<String>).value;
  });

  tearDown(() async {
    for (final c in [priyaClient, quinlanClient, remyClient]) {
      await c.removeAllChannels();
    }
  });

  tearDownAll(() async {
    for (final c in [priyaClient, quinlanClient, remyClient]) {
      await c.dispose();
    }
  });

  Future<String> send() async {
    final r = await priyaChat.send(
      id: randomMessageId(),
      conversationId: club,
      body: 'seam ${DateTime.now().microsecondsSinceEpoch}',
    );
    return (r as Ok<Message>).value.id;
  }

  test(
    'a react on one phone shows on the other, live; a clear removes it',
    () async {
      final m = await send();
      final priya = await opened(priyaClient, priyaId);
      final quinlan = await opened(quinlanClient, quinlanId);

      final set = await priya.read(reactionsProvider.notifier).react(m, '👍');
      expect(set, isA<Ok<void>>(), reason: '$set');
      expect(_shape(priya)[m], {(priyaId, '👍')});
      await _until(
        () => _shape(quinlan)[m]?.contains((priyaId, '👍')) ?? false,
        'the reaction on quinlan\'s phone',
      );

      expect(
        await priya.read(reactionsProvider.notifier).react(m, null),
        isA<Ok<void>>(),
      );
      await _until(() => _shape(quinlan)[m] == null, 'the clear');
      expect(_shape(priya)[m], isNull);
    },
  );

  test(
    'a non-member\'s react is refused as DeniedFailure and rolled back',
    () async {
      final m = await send();
      final remy = await opened(remyClient, remyId);
      expect(_shape(remy), isEmpty);
      final result = await remy.read(reactionsProvider.notifier).react(m, '👍');
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(_shape(remy), isEmpty);
    },
  );
}
