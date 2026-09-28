@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';

/// The controller seam against the real stack.
///
/// The widget tests prove the controllers behave with a fake underneath them;
/// they cannot prove the wiring is real. Here every provider is backed by
/// [SupabaseChatRepository] talking to a running local Supabase: real
/// PostgREST, real RPC, real Realtime, real row-level security — plus the
/// failure path of each connection, which a fake can only imitate.
///
/// Requires `docker compose run --rm supabase start`. Uses its own pair of
/// seeded accounts: signing in claims the active device, so sharing ann/bob
/// with chat_repository_test.dart would break both suites in a parallel run.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client(String url) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> signedIn(String email) async {
  final client = _client(_url);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

/// Never the raw SDK error that produced the message: no exception name, no
/// status/error code, no socket detail.
void expectNoRawText(String message) {
  for (final needle in [
    'Exception',
    'statusCode',
    'errno',
    'Failed host lookup',
  ]) {
    expect(
      message,
      isNot(contains(needle)),
      reason: 'raw error text reached the screen: $message',
    );
  }
}

/// The offline message, and nothing of the raw SDK error that produced it.
void expectOffline(String message) {
  expect(message, offlineMessage);
  expectNoRawText(message);
}

ProviderContainer containerFor(ChatRepositoryOwner owner) =>
    ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(owner.repository)],
    );

/// Keeps the repository and the client it was built on together, so a test
/// cannot accidentally use a disposed client.
class ChatRepositoryOwner {
  ChatRepositoryOwner(this.client)
    : repository = SupabaseChatRepository(client);
  final SupabaseClient client;
  final SupabaseChatRepository repository;
  String get userId => client.auth.currentUser!.id;
}

/// Polls [read] until [matches] holds; Realtime has no callback here.
Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 25),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (matches(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out after $timeout: $reason');
}

void main() {
  SupabaseClient? carolClient;
  SupabaseClient? danClient;
  SupabaseClient? deadClient;
  SupabaseClient? deadSignedInClient;
  late ChatRepositoryOwner carol;
  late ChatRepositoryOwner dan;
  late ChatRepositoryOwner offline;
  // Same account as carol, same dead host, but with a real session: reaches
  // the offline path of members()/conversations()/send(), which first check
  // `auth.currentUser` and would otherwise short-circuit to DeniedFailure.
  late ChatRepositoryOwner offlineSignedIn;
  late String conversationId;

  setUpAll(() async {
    danClient = await signedIn('dan@integration.test');
    carolClient = await signedIn('carol@integration.test');
    carol = ChatRepositoryOwner(carolClient!);
    dan = ChatRepositoryOwner(danClient!);
    deadClient = deadHostClient();
    offline = ChatRepositoryOwner(deadClient!);
    deadSignedInClient = await deadButSignedIn(carolClient!);
    offlineSignedIn = ChatRepositoryOwner(deadSignedInClient!);

    final started = await carol.repository.startDirectConversation(dan.userId);
    expect(started, isA<Ok<String>>());
    conversationId = (started as Ok<String>).value;
    // Something to read: the list and the message screen both need history.
    await carol.repository.send(
      id: randomMessageId(),
      conversationId: conversationId,
      body: 'seed ${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDownAll(() async {
    await carolClient?.dispose();
    await danClient?.dispose();
    await deadClient?.dispose();
    await deadSignedInClient?.dispose();
  });

  test('the conversation list controller loads real conversations', () async {
    final container = containerFor(carol);
    final list = await container.read(conversationListProvider.future);

    final row = list.firstWhere(
      (c) => c.id == conversationId,
      orElse: () => fail('the real conversation is missing from the list'),
    );
    expect(row.other!.userId, dan.userId);
    expect(row.other!.displayName, isNotEmpty);
    expect(row.lastMessage, isNotNull, reason: 'the preview column must load');
  });

  test('members lists the other member through the real query', () async {
    final container = containerFor(carol);
    final members = await container.read(yourPeopleProvider.future);

    expect(
      members.map((m) => m.userId),
      contains(dan.userId),
      reason: 'no one to start a conversation with',
    );
    expect(members.map((m) => m.userId), isNot(contains(carol.userId)));
  });

  test('startWith reaches the RPC and the list then holds it', () async {
    final container = containerFor(carol);
    await container.read(conversationListProvider.future);

    final result = await container
        .read(conversationListProvider.notifier)
        .startWith(dan.userId);

    expect(result, isA<Ok<String>>());
    expect(
      (result as Ok<String>).value,
      conversationId,
      reason: 'the RPC must be idempotent for the same pair',
    );
    final list = await eventually<List<Conversation>>(
      () => container.read(conversationListProvider).value ?? const [],
      (l) => l.any((c) => c.id == conversationId),
      reason: 'the list did not refresh after starting a conversation',
    );
    expect(list.map((c) => c.id), contains(conversationId));
  });

  test(
    'the messages controller loads and send() reaches the database',
    () async {
      final container = containerFor(carol);
      container.read(openConversationProvider.notifier).open(conversationId);
      // Keeps the controller and its subscription alive; a bare read lets it
      // dispose between polls and re-subscribe from scratch.
      container.listen(messagesProvider, (_, _) {});

      final loaded = await container.read(messagesProvider.future);
      expect(loaded, isNotEmpty, reason: 'the seeded message must load');
      expect(loaded.every((m) => m.conversationId == conversationId), isTrue);

      final body = 'controller ${DateTime.now().microsecondsSinceEpoch}';
      final pending = container
          .read(sendQueueProvider.notifier)
          .enqueue(conversationId, body: body);

      // The database, not the controller's optimism, is the witness.
      var theirs = const <Message>[];
      for (var i = 0; i < 100 && !theirs.any((m) => m.body == body); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final r = await dan.repository.messages(conversationId);
        if (r case Ok(:final value)) theirs = value;
      }
      expect(
        theirs.singleWhere((m) => m.body == body).id,
        pending.id,
        reason: 'stored under the id the phone chose',
      );
      await eventually<List<Message>>(
        () => container.read(messagesProvider).value ?? const [],
        (l) => l.any((m) => m.id == pending.id && !m.sending),
        reason: 'the sent message never became the stored one in state',
      );
    },
  );

  test('a Realtime message from the other member lands in state', () async {
    final container = containerFor(carol);
    container.read(openConversationProvider.notifier).open(conversationId);
    // Keeps the controller (and its subscription) alive for the whole test.
    container.listen(messagesProvider, (_, _) {});
    // Completes only once the subscription is confirmed, so the send below
    // cannot race the join.
    await container.read(messagesProvider.future);

    final body = 'realtime ${DateTime.now().microsecondsSinceEpoch}';
    expect(
      await dan.repository.send(
        id: randomMessageId(),
        conversationId: conversationId,
        body: body,
      ),
      isA<Ok<void>>(),
    );

    final state = await eventually<List<Message>>(
      () => container.read(messagesProvider).value ?? const [],
      (l) => l.any((m) => m.body == body),
      reason: 'Realtime never reached the controller state',
    );
    final delivered = state.firstWhere((m) => m.body == body);
    expect(delivered.senderId, dan.userId);
    expect(delivered.isFrom(carol.userId), isFalse);
    expect(
      state.where((m) => m.body == body),
      hasLength(1),
      reason: 'the same message was added twice',
    );
  });

  test('a send to a conversation the member is not in is refused: the text '
      'goes back to the draft with a notice, and is not retried', () async {
    final container = containerFor(carol);
    const stranger = '00000000-0000-0000-0000-000000000000';
    container.read(openConversationProvider.notifier).open(stranger);
    container.listen(messagesProvider, (_, _) {});
    container.listen(sendQueueProvider, (_, _) {});
    await container.read(messagesProvider.future);

    final body = 'not mine ${DateTime.now().microsecondsSinceEpoch}';
    container.read(sendQueueProvider.notifier).enqueue(stranger, body: body);

    final drafts = container.read(draftsProvider.notifier);
    await eventually<String>(
      () => drafts.draftFor(stranger).text,
      (text) => text == body,
      reason:
          'row-level security must refuse a stranger, and the refusal '
          'must come back as a draft, not wait as if offline',
    );
    expect(container.read(sendQueueProvider)[stranger] ?? const [], isEmpty);
    final failure = drafts.consumeFailure(stranger);
    expect(failure, isNotNull);
    expect(failure!.message, isNotEmpty);
  });

  test(
    'a broken connection fails the list with a reason, not a spinner',
    () async {
      final container = containerFor(offlineSignedIn);
      container.listen(conversationListProvider, (_, _) {});

      final state = await eventually<AsyncValue<List<Conversation>>>(
        () => container.read(conversationListProvider),
        (s) => !s.isLoading,
        reason: 'the list spun forever on an unreachable server',
      );
      expect(state, isA<AsyncError<List<Conversation>>>());
      expectOffline((state.error! as Failure).message);
    },
  );

  test('a broken connection fails the messages screen with a reason', () async {
    final container = containerFor(offline);
    container.read(openConversationProvider.notifier).open(conversationId);
    container.listen(messagesProvider, (_, _) {});

    final state = await eventually<AsyncValue<List<Message>>>(
      () => container.read(messagesProvider),
      (s) => !s.isLoading,
      timeout: const Duration(seconds: 40),
      reason: 'the message screen spun forever on an unreachable server',
    );
    expect(state, isA<AsyncError<List<Message>>>());
    // `incoming()` is the one call that signals failure by throwing, and the
    // SDK throws its own exception type (`WebSocketChannelException`,
    // wrapping the refused socket). It must be mapped to a Failure: the
    // screen renders `error.toString()` for anything else, which puts a raw
    // WebSocketChannelException in front of a member.
    expect(
      state.error,
      isA<Failure>(),
      reason: 'a raw SDK exception reached the screen',
    );
    expectOffline((state.error! as Failure).message);
  });

  test('a broken connection fails members with a reason', () async {
    final container = containerFor(offlineSignedIn);
    container.listen(yourPeopleProvider, (_, _) {});

    final state = await eventually<AsyncValue<List<Member>>>(
      () => container.read(yourPeopleProvider),
      (s) => !s.isLoading,
      reason: 'the member picker spun forever on an unreachable server',
    );
    expect(state, isA<AsyncError<List<Member>>>());
    expectOffline((state.error! as Failure).message);
  });

  test(
    'a broken connection refuses startWith and send with a reason',
    () async {
      final container = containerFor(offline);

      final started = await container
          .read(conversationListProvider.notifier)
          .startWith('00000000-0000-0000-0000-000000000000');
      expect(started, isA<Err<String>>());
      expectOffline((started as Err<String>).failure.message);

      final sent = await offlineSignedIn.repository.send(
        id: randomMessageId(),
        conversationId: conversationId,
        body: 'never arrives',
      );
      expect(sent, isA<Err<void>>());
      expectOffline((sent as Err<void>).failure.message);
    },
  );
}
