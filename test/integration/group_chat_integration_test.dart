@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Groups through the real stack.
///
/// The widget and controller tests prove the controllers behave with a fake
/// underneath them. They cannot prove that `start_group_conversation` takes
/// the arguments the repository sends, that row-level security lets all three
/// members in and keeps a fourth out. Every provider here is backed by
/// [SupabaseChatRepository] against a running local Supabase. Display names
/// and tags moved to the profile feature in v0.4; the rename coverage that
/// lived here is in profile_integration_test.dart.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts: signing in claims the active device, so sharing a pair with
/// another suite would evict it.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A host that accepts nothing: the honest form of "the connection failed".
const _deadUrl = 'http://127.0.0.1:1';

/// An account that does not exist, to stand in for an invitee the caller may
/// not add.
const _ghost = '00000000-0000-0000-0000-0000000000ff';

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

/// Keeps the repository and the client it was built on together.
class ChatRepositoryOwner {
  ChatRepositoryOwner(this.client)
    : repository = SupabaseChatRepository(client);
  final SupabaseClient client;
  final SupabaseChatRepository repository;
  String get userId => client.auth.currentUser!.id;
}

ProviderContainer containerFor(ChatRepositoryOwner owner) =>
    ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(owner.repository)],
    );

/// A fresh read of [owner]'s conversations through their own controller.
Future<List<Conversation>> listOf(ChatRepositoryOwner owner) =>
    containerFor(owner).read(conversationListProvider.future);

String nonce() => DateTime.now().microsecondsSinceEpoch.toString();

void main() {
  SupabaseClient? hankClient;
  SupabaseClient? ivyClient;
  SupabaseClient? jackClient;
  SupabaseClient? kimClient;
  SupabaseClient? deadClient;
  late ChatRepositoryOwner hank;
  late ChatRepositoryOwner ivy;
  late ChatRepositoryOwner jack;
  late ChatRepositoryOwner kim;
  late ChatRepositoryOwner offline;

  setUpAll(() async {
    hankClient = await signedIn('hank@integration.test');
    ivyClient = await signedIn('ivy@integration.test');
    jackClient = await signedIn('jack@integration.test');
    kimClient = await signedIn('kim@integration.test');
    deadClient = _client(_deadUrl);
    hank = ChatRepositoryOwner(hankClient!);
    ivy = ChatRepositoryOwner(ivyClient!);
    jack = ChatRepositoryOwner(jackClient!);
    kim = ChatRepositoryOwner(kimClient!);
    offline = ChatRepositoryOwner(deadClient!);
  });

  tearDownAll(() async {
    await hankClient?.dispose();
    await ivyClient?.dispose();
    await jackClient?.dispose();
    await kimClient?.dispose();
    await deadClient?.dispose();
  });

  test(
    'a real group of three: every member reads it, a fourth does not',
    () async {
      final title = 'Trip ${nonce()}';
      final container = containerFor(hank);
      await container.read(conversationListProvider.future);

      final created = await container
          .read(conversationListProvider.notifier)
          .startGroup(title: title, memberIds: [ivy.userId, jack.userId]);
      expect(
        created,
        isA<Ok<String>>(),
        reason: created is Err<String>
            ? 'the RPC refused: ${created.failure.message}'
            : '',
      );
      final id = (created as Ok<String>).value;

      // The creator's own list, refreshed by the controller.
      final hankList =
          container.read(conversationListProvider).value ?? const [];
      final mine = hankList.firstWhere(
        (c) => c.id == id,
        orElse: () => fail('the new group is missing from the creator\'s list'),
      );
      expect(mine.isGroup, isTrue);
      expect(mine.title, title);
      expect(mine.label, title, reason: 'a group is labelled by its title');
      expect(
        mine.other,
        isNull,
        reason: 'a group has no single other member to name',
      );

      // Both invitees read it, with the same label.
      for (final member in [ivy, jack]) {
        final row = (await listOf(member)).where((c) => c.id == id);
        expect(
          row,
          hasLength(1),
          reason: 'an invited member cannot see the group',
        );
        expect(row.single.label, title);
        expect(row.single.isGroup, isTrue);
      }

      // And they read what is said in it.
      final body = 'group hello ${nonce()}';
      expect(
        await hank.repository.send(conversationId: id, body: body),
        isA<Ok<Message>>(),
      );
      for (final member in [ivy, jack]) {
        final messages = await member.repository.messages(id);
        expect(
          (messages as Ok<List<Message>>).value.map((m) => m.body),
          contains(body),
          reason: 'a group member could not read the group message',
        );
      }

      // Kim is allowlisted and active — only membership keeps her out.
      expect(
        (await listOf(kim)).map((c) => c.id),
        isNot(contains(id)),
        reason: 'a non-member sees the group in her list',
      );
      final hers = await kim.repository.messages(id);
      expect(
        hers is Ok<List<Message>> ? hers.value : const <Message>[],
        isEmpty,
        reason: 'a non-member read the group messages',
      );
      expect(
        await kim.repository.send(conversationId: id, body: 'gatecrashing'),
        isA<Err<Message>>(),
        reason: 'a non-member posted into the group',
      );
    },
  );

  test('one invitee the caller may not add fails the whole call', () async {
    final title = 'Ghost ${nonce()}';
    final container = containerFor(hank);
    await container.read(conversationListProvider.future);

    final result = await container
        .read(conversationListProvider.notifier)
        .startGroup(title: title, memberIds: [ivy.userId, _ghost]);

    expect(result, isA<Err<String>>());
    expect((result as Err<String>).failure.message, isNotEmpty);
    // The rule is not "refuse", it is "create nothing": a smaller group than
    // was asked for is the defect.
    expect(
      (await listOf(hank)).where((c) => c.title == title),
      isEmpty,
      reason: 'a refused group was created anyway, without the invitee',
    );
    expect(
      (await listOf(ivy)).where((c) => c.title == title),
      isEmpty,
      reason: 'the invitee was added to a group that was refused',
    );
  });

  test('the same people may hold several groups with the same name', () async {
    final title = 'Twice ${nonce()}';
    final container = containerFor(hank);
    await container.read(conversationListProvider.future);
    final notifier = container.read(conversationListProvider.notifier);

    final first = await notifier.startGroup(
      title: title,
      memberIds: [ivy.userId],
    );
    final second = await notifier.startGroup(
      title: title,
      memberIds: [ivy.userId],
    );

    expect(first, isA<Ok<String>>());
    expect(second, isA<Ok<String>>());
    expect(
      (second as Ok<String>).value,
      isNot((first as Ok<String>).value),
      reason: 'the group RPC reused a conversation instead of creating one',
    );
    final ids = (await listOf(ivy))
        .where((c) => c.title == title)
        .map((c) => c.id);
    expect(ids, containsAll([first.value, second.value]));
  });

  test('an empty title is refused and creates nothing', () async {
    final container = containerFor(hank);
    final before = await container.read(conversationListProvider.future);

    final result = await container
        .read(conversationListProvider.notifier)
        .startGroup(title: '   ', memberIds: [ivy.userId]);

    expect(result, isA<Err<String>>());
    expect((result as Err<String>).failure.message, isNotEmpty);
    expect(
      (await listOf(hank)).length,
      before.length,
      reason: 'a nameless group was created',
    );
  });

  test('a group with nobody else in it is refused', () async {
    final container = containerFor(hank);

    final result = await container
        .read(conversationListProvider.notifier)
        .startGroup(title: 'Alone ${nonce()}', memberIds: const []);

    expect(result, isA<Err<String>>());
    expect((result as Err<String>).failure.message, isNotEmpty);
  });

  test('a broken connection refuses the call with a reason', () async {
    final container = containerFor(offline);

    final group = await container
        .read(conversationListProvider.notifier)
        .startGroup(title: 'Offline', memberIds: [ivy.userId]);
    expect(group, isA<Err<String>>());
    expect((group as Err<String>).failure.message, isNotEmpty);
  });
}
