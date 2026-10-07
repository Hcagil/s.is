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
import 'package:sis/features/chat/data/supabase_poll_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/poll.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';

/// The seam PollsController <-> SupabasePollRepository <-> the local stack,
/// wired as main.dart wires it (pollRepositoryProvider overridden with the
/// Supabase repository): a poll created on one phone is voted, retracted and
/// closed there, and the other member's open chat follows live; a
/// non-member's vote comes back as DeniedFailure (42501), a vote on a closed
/// poll as PollClosedFailure (55000). Run with --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
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

Future<void> _until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Failure _failure(Result<void> r) => (r as Err<void>).failure;

void main() {
  late SupabaseClient priyaClient, quinlanClient, remyClient;
  late String priyaId, quinlanId, remyId;
  late String club;

  Future<ProviderContainer> opened(SupabaseClient client, String id) async {
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(ChatFake()),
        pollRepositoryProvider.overrideWithValue(
          SupabasePollRepository(client),
        ),
        sessionControllerProvider.overrideWith(() => _As(id)),
      ],
    );
    addTearDown(c.dispose);
    await settled(c);
    c.listen(pollsProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(club);
    await c.read(pollsProvider.future);
    // Let the join land and the reconcile settle.
    await Future<void>.delayed(const Duration(seconds: 1));
    return c;
  }

  Poll? of(ProviderContainer c, String m) => c.read(pollsProvider).value?[m];

  /// Priya stores a fresh poll in the club; returns its message id.
  Future<String> create({bool anonymous = false}) async {
    final m = randomMessageId();
    final r = await SupabasePollRepository(priyaClient).createPoll(
      club,
      m,
      PollDraft(
        question: 'Lunch? ${DateTime.now().microsecondsSinceEpoch}',
        options: const ['Pizza', 'Soup'],
        multiple: false,
        anonymous: anonymous,
      ),
    );
    expect(r, isA<Ok<void>>(), reason: '$r');
    return m;
  }

  setUpAll(() async {
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priyaId = priyaClient.auth.currentUser!.id;
    quinlanId = quinlanClient.auth.currentUser!.id;
    remyId = remyClient.auth.currentUser!.id;
    final priyaChat = SupabaseChatRepository(priyaClient);
    final title = 'polls seam ${DateTime.now().microsecondsSinceEpoch}';
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

  test(
    'create, vote, retract and close; the other phone follows live',
    () async {
      final m = await create();
      final priya = await opened(priyaClient, priyaId);
      final quinlan = await opened(quinlanClient, quinlanId);
      final p = of(priya, m)!;
      expect(p.options.map((o) => o.text), ['Pizza', 'Soup']);
      expect(of(quinlan, m)!.voters, 0);
      final pizza = p.options[0].id;

      final voted = await priya.read(pollsProvider.notifier).vote(m, {pizza});
      expect(voted, isA<Ok<void>>(), reason: '$voted');
      expect(of(priya, m)!.mine, {pizza});
      await _until(
        () => of(quinlan, m)?.options[0].votes == 1,
        'the vote on quinlan\'s phone',
      );
      expect(of(quinlan, m)!.voters, 1);
      expect(of(quinlan, m)!.mine, isEmpty);

      final retracted = await priya.read(pollsProvider.notifier).retract(m);
      expect(retracted, isA<Ok<void>>(), reason: '$retracted');
      await _until(
        () => of(quinlan, m)?.options[0].votes == 0,
        'the retract on quinlan\'s phone',
      );
      expect(of(priya, m)!.mine, isEmpty);
      expect(of(quinlan, m)!.voters, 0);

      final closed = await priya.read(pollsProvider.notifier).close(m);
      expect(closed, isA<Ok<void>>(), reason: '$closed');
      await _until(
        () => of(quinlan, m)?.closed ?? false,
        'the close on quinlan\'s phone',
      );
      expect(of(priya, m)!.closed, isTrue);
    },
  );

  test('a non-member\'s vote is refused as DeniedFailure', () async {
    final m = await create();
    final priya = await opened(priyaClient, priyaId);
    final pizza = of(priya, m)!.options[0].id;
    final r = await SupabasePollRepository(remyClient).vote(m, {pizza});
    expect(_failure(r), isA<DeniedFailure>());
  });

  test('a vote on a closed poll is refused as PollClosedFailure', () async {
    final m = await create();
    final priya = await opened(priyaClient, priyaId);
    final quinlan = await opened(quinlanClient, quinlanId);
    final pizza = of(priya, m)!.options[0].id;
    expect(await priya.read(pollsProvider.notifier).close(m), isA<Ok<void>>());
    final r = await SupabasePollRepository(quinlanClient).vote(m, {pizza});
    expect(_failure(r), isA<PollClosedFailure>());
    // Through the controller too: refused, and nothing counted.
    await _until(() => of(quinlan, m)?.closed ?? false, 'the close');
    final v = await quinlan.read(pollsProvider.notifier).vote(m, {pizza});
    expect(_failure(v), isA<PollClosedFailure>());
    expect(of(quinlan, m)!.options[0].votes, 0);
  });

  test(
    'a close by anyone but the creator is refused as DeniedFailure',
    () async {
      final m = await create();
      final quinlan = await opened(quinlanClient, quinlanId);
      final r = await quinlan.read(pollsProvider.notifier).close(m);
      expect(_failure(r), isA<DeniedFailure>());
      expect(of(quinlan, m)!.closed, isFalse);
    },
  );
}
