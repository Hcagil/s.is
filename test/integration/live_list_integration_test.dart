@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The live conversation list against the real stack: the REAL
/// [ConversationListController] on the REAL [SupabaseChatRepository], with
/// real Realtime deciding per subscriber, through row-level security, which
/// inserts arrive.
///
/// The unit tests prove the controller reacts correctly to a stream a fake
/// hands it. They cannot prove that `incomingAll()` really delivers every
/// conversation the member is in, that it is ready when it says it is, or
/// that it withholds a conversation the member is not in.
///
/// Requires a running local Supabase and the warmup probe. Accounts
/// rose/sam/tess are this suite's own (supabase/seed.sql).
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

SupabaseClient _client(String url) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
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

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

/// Every real call goes to [live]; only the list-wide subscription goes to a
/// real repository on a dead host. That is the one failure the list must
/// survive — reads working, Realtime not — and both halves are the real
/// implementation, so the Err is the one production produces.
class _RealtimeDown implements ChatRepository {
  _RealtimeDown(this.live, this.dead);
  final ChatRepository live;
  final ChatRepository dead;

  @override
  Future<Result<Stream<Message>>> incomingAll() => dead.incomingAll();
  @override
  Future<Result<List<Conversation>>> conversations() => live.conversations();
  @override
  Future<Result<List<Member>>> members() => live.members();
  @override
  Future<Result<List<Member>>> conversationMembers(String id) =>
      live.conversationMembers(id);
  @override
  Future<Result<List<Message>>> sharedMedia(String id) => live.sharedMedia(id);
  @override
  Future<Result<List<Message>>> sharedLinks(String id) => live.sharedLinks(id);
  @override
  Future<Result<void>> markRead(String id) => live.markRead(id);
  @override
  Future<Result<List<Message>>> messages(String id) => live.messages(id);
  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
  }) => live.send(conversationId: conversationId, body: body);
  @override
  Future<Result<Stream<Message>>> incoming(String id) => live.incoming(id);
  @override
  Future<Result<String>> startDirectConversation(String other) =>
      live.startDirectConversation(other);
  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) => live.startGroupConversation(title: title, memberIds: memberIds);
  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
  }) =>
      live.sendImage(conversationId: conversationId, image: image, body: body);
  @override
  Future<Result<Uri>> attachmentUrl(String path) => live.attachmentUrl(path);
  @override
  Future<Result<Uint8List>> attachmentBytes(String path) =>
      live.attachmentBytes(path);
  @override
  Future<Result<void>> deleteForEveryone(Message message) =>
      live.deleteForEveryone(message);
}

/// A container wired as production mounts it: only the repository provider
/// is overridden, with the real repository.
ProviderContainer _containerFor(ChatRepository repository) =>
    ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(repository)],
    );

/// Loads the list and keeps the controller (and its subscription) alive.
Future<ProviderContainer> _liveList(ChatRepository repository) async {
  final container = _containerFor(repository);
  container.listen(conversationListProvider, (_, _) {});
  await container.read(conversationListProvider.future);
  return container;
}

List<Conversation> _list(ProviderContainer c) =>
    c.read(conversationListProvider).value ?? const [];

void main() {
  SupabaseClient? roseClient;
  SupabaseClient? samClient;
  SupabaseClient? tessClient;
  SupabaseClient? deadClient;
  late SupabaseChatRepository rose;
  late SupabaseChatRepository sam;
  late SupabaseChatRepository tess;
  late String roseId;
  late String samId;

  /// rose <-> sam: tess is never in it.
  late String roseSam;

  /// tess <-> sam: tess's own traffic, so her silence on [roseSam] is shown
  /// to be RLS and not a dead subscription.
  late String tessSam;

  /// A group of rose and sam, written to last in setup so it starts on top.
  late String roseGroup;

  setUpAll(() async {
    samClient = await _signedIn('sam@integration.test');
    tessClient = await _signedIn('tess@integration.test');
    roseClient = await _signedIn('rose@integration.test');
    deadClient = _client(_deadUrl);
    rose = SupabaseChatRepository(roseClient!);
    sam = SupabaseChatRepository(samClient!);
    tess = SupabaseChatRepository(tessClient!);
    roseId = roseClient!.auth.currentUser!.id;
    samId = samClient!.auth.currentUser!.id;

    roseSam = (await rose.startDirectConversation(samId) as Ok<String>).value;
    tessSam = (await tess.startDirectConversation(samId) as Ok<String>).value;
    roseGroup = (await rose.startGroupConversation(
      title: _stamp('top'),
      memberIds: [samId],
    ) as Ok<String>).value;
    expect(
      await rose.send(conversationId: roseSam, body: _stamp('seed')),
      isA<Ok<Message>>(),
    );
    expect(
      await tess.send(conversationId: tessSam, body: _stamp('seed')),
      isA<Ok<Message>>(),
    );
  });

  tearDownAll(() async {
    await roseClient?.dispose();
    await samClient?.dispose();
    await tessClient?.dispose();
    await deadClient?.dispose();
  });

  /// Puts [roseGroup] on top of rose's list, so a move to the top is a move.
  Future<void> groupOnTop() async {
    expect(
      await rose.send(conversationId: roseGroup, body: _stamp('bump')),
      isA<Ok<Message>>(),
    );
  }

  group('SupabaseChatRepository.incomingAll', () {
    test(
      'is ready when it resolves, and spans every conversation of the member',
      () async {
        final opened = await rose.incomingAll();
        expect(opened, isA<Ok<Stream<Message>>>());
        // Resolved means the server confirmed the join; a channel still
        // joining here means the caller's first read races the subscription.
        final channels = roseClient!.getChannels();
        expect(channels, isNotEmpty, reason: 'no channel was opened');
        expect(
          channels.every((c) => c.canPush),
          isTrue,
          reason: 'incomingAll() resolved before Realtime confirmed the join',
        );
        final seen = <Message>[];
        final sub = (opened as Ok<Stream<Message>>).value.listen(seen.add);
        addTearDown(sub.cancel);

        // No settling delay: resolved means confirmed, so an insert made the
        // moment it resolves must arrive.
        final direct = _stamp('direct');
        final grouped = _stamp('group');
        await sam.send(conversationId: roseSam, body: direct);
        await sam.send(conversationId: roseGroup, body: grouped);

        await eventually<List<Message>>(
          () => seen,
          (s) =>
              s.any((m) => m.body == direct) && s.any((m) => m.body == grouped),
          reason: 'an insert right after incomingAll() resolved never arrived',
        );
        final m = seen.firstWhere((m) => m.body == direct);
        expect(m.conversationId, roseSam);
        expect(m.senderId, samId);
        expect(
          seen.firstWhere((m) => m.body == grouped).conversationId,
          roseGroup,
        );
      },
    );

    test(
      'a non-member receives nothing from a conversation he is not in',
      () async {
        final tessSeen = <Message>[];
        final roseSeen = <Message>[];
        final tessSub = ((await tess.incomingAll()) as Ok<Stream<Message>>)
            .value
            .listen(tessSeen.add);
        final roseSub = ((await rose.incomingAll()) as Ok<Stream<Message>>)
            .value
            .listen(roseSeen.add);
        addTearDown(tessSub.cancel);
        addTearDown(roseSub.cancel);

        final secret = _stamp('not for tess');
        final hers = _stamp('for tess');
        await sam.send(conversationId: roseSam, body: secret);
        await sam.send(conversationId: tessSam, body: hers);

        // Positive controls on both sides: rose's stream carried the secret,
        // and tess's is live — it carried the later message meant for her.
        await eventually<List<Message>>(
          () => roseSeen,
          (s) => s.any((m) => m.body == secret),
          reason: 'the member never received it, so silence proves nothing',
        );
        await eventually<List<Message>>(
          () => tessSeen,
          (s) => s.any((m) => m.body == hers),
          reason: "tess's subscription is dead, so silence proves nothing",
        );
        // Grace for any out-of-order straggler.
        await Future<void>.delayed(const Duration(seconds: 2));

        expect(
          tessSeen.where(
            (m) => m.conversationId == roseSam || m.body == secret,
          ),
          isEmpty,
          reason: 'Realtime handed a non-member a message from rose and sam',
        );
        expect(tessSeen.every((m) => m.conversationId == tessSam), isTrue);
      },
    );
  });

  group('ConversationListController on the real repository', () {
    test("a message from the other member updates the list live", () async {
      await groupOnTop();
      final container = await _liveList(rose);
      addTearDown(container.dispose);
      expect(
        _list(container).first.id,
        roseGroup,
        reason: 'fixture: the group must start on top',
      );

      final body = _stamp('live');
      await sam.send(conversationId: roseSam, body: body);

      final list = await eventually<List<Conversation>>(
        () => _list(container),
        (l) => l.isNotEmpty && l.first.lastMessage == body,
        reason: 'the list never showed the new message on top',
      );
      final top = list.first;
      expect(top.id, roseSam);
      expect(top.lastSenderId, samId);
      expect(top.lastMessageAt, isNotNull);
      expect(top.other?.userId, samId);
      expect(list.where((c) => c.id == roseSam), hasLength(1));
    });

    test(
      'sending from the message screen updates the list behind it',
      () async {
        await groupOnTop();
        final container = await _liveList(rose);
        addTearDown(container.dispose);

        container.read(openConversationProvider.notifier).open(roseSam);
        container.listen(messagesProvider, (_, _) {});
        await container.read(messagesProvider.future);

        final body = _stamp('mine');
        expect(
          await container.read(messagesProvider.notifier).send(body),
          isA<Ok<Message>>(),
        );

        final top = (await eventually<List<Conversation>>(
          () => _list(container),
          (l) => l.isNotEmpty && l.first.lastMessage == body,
          reason: 'own message never reached the list: the old preview stays',
        )).first;
        expect(top.id, roseSam);
        expect(top.lastSenderId, roseId);
      },
    );

    test(
      "a conversation started by someone else appears in the list",
      () async {
        final container = await _liveList(rose);
        addTearDown(container.dispose);

        final title = _stamp('from sam');
        final started = await sam.startGroupConversation(
          title: title,
          memberIds: [roseId],
        );
        final id = (started as Ok<String>).value;
        expect(_list(container).map((c) => c.id), isNot(contains(id)));

        final body = _stamp('hello rose');
        await sam.send(conversationId: id, body: body);

        final list = await eventually<List<Conversation>>(
          () => _list(container),
          (l) => l.any((c) => c.id == id && c.lastMessage == body),
          reason: 'a conversation somebody else started never appeared',
        );
        expect(list.first.id, id);
        expect(list.first.title, title);
        expect(list.first.lastSenderId, samId);
      },
    );

    test("a non-member's list receives nothing", () async {
      final roseList = await _liveList(rose);
      final tessList = await _liveList(tess);
      addTearDown(roseList.dispose);
      addTearDown(tessList.dispose);

      final secret = _stamp('rose only');
      await sam.send(conversationId: roseSam, body: secret);
      await eventually<List<Conversation>>(
        () => _list(roseList),
        (l) => l.isNotEmpty && l.first.lastMessage == secret,
        reason: 'positive control: rose never got it',
      );

      final hers = _stamp('tess only');
      await sam.send(conversationId: tessSam, body: hers);
      await eventually<List<Conversation>>(
        () => _list(tessList),
        (l) => l.isNotEmpty && l.first.lastMessage == hers,
        reason: "positive control: tess's list is not live",
      );

      final tessState = _list(tessList);
      expect(tessState.map((c) => c.id), isNot(contains(roseSam)));
      expect(tessState.map((c) => c.lastMessage), isNot(contains(secret)));
    });

    test(
      'Realtime unreachable: the list still loads from the database',
      () async {
        final container = _containerFor(
          _RealtimeDown(rose, SupabaseChatRepository(deadClient!)),
        );
        addTearDown(container.dispose);
        container.listen(conversationListProvider, (_, _) {});

        final state = await eventually<AsyncValue<List<Conversation>>>(
          () => container.read(conversationListProvider),
          (s) => !s.isLoading,
          timeout: const Duration(seconds: 60),
          reason: 'the list spun forever on a dead subscription',
        );
        expect(
          state.hasError,
          isFalse,
          reason: 'a failed subscription failed the whole list: ${state.error}',
        );
        expect(state.requireValue.map((c) => c.id), contains(roseSam));

        // The fallback then keeps it current.
        final body = _stamp('quiet');
        await sam.send(conversationId: roseSam, body: body);
        await container.read(conversationListProvider.notifier).reloadQuietly();
        expect(_list(container).first.lastMessage, body);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
