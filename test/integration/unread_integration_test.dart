@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/dead_host.dart';

/// Unread counts through the real stack: [SupabaseChatRepository.markRead]
/// and `conversations().unread` against the real RPCs, and the seam the
/// counts live on -- the REAL [ConversationListController] fed by real
/// Realtime, and the real list and message screens -- checked against what the
/// server says on a fresh read.
///
/// Requires a running local Supabase and the warmup probe. Accounts una, otto
/// and pia are this suite's own (supabase/seed.sql).
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

/// Google sign-in cannot run locally, so this is the one boundary faked: the
/// session is the account's real one, activated against the real database.
class _AccountAuth implements AuthRepository {
  _AccountAuth(this.client, this.name);
  final SupabaseClient client;
  final String name;

  @override
  bool get hasSession => client.auth.currentSession != null;
  @override
  Stream<bool> get signedInChanges => const Stream.empty();
  @override
  Future<Result<void>> signInWithGoogle() async => const Ok(null);
  @override
  Future<Result<bool>> activateSession() async =>
      Ok(await client.rpc('activate_session') as bool);
  @override
  Future<Result<Member>> currentMember() async =>
      Ok(Member(userId: client.auth.currentUser!.id, displayName: name));
  @override
  Future<void> signOut() async {}
}

/// Everything goes to [live] except markRead, which goes to a real
/// repository on a dead host: the connection that fails is the real one.
class _MarkReadDown implements ChatRepository {
  _MarkReadDown(this.live, this.dead);
  final ChatRepository live;
  final ChatRepository dead;

  @override
  Future<Result<void>> markRead(String id) => dead.markRead(id);
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
  Future<Result<List<Message>>> messages(String id) => live.messages(id);
  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
    String? replyTo,
  }) => live.send(conversationId: conversationId, body: body, replyTo: replyTo);
  @override
  Future<Result<void>> forward(Message message, List<String> ids) =>
      live.forward(message, ids);
  @override
  Future<Result<Stream<Message>>> incoming(String id) => live.incoming(id);
  @override
  Future<Result<Stream<Message>>> incomingAll() => live.incomingAll();
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
    String? replyTo,
  }) => live.sendImage(
    conversationId: conversationId,
    image: image,
    body: body,
    replyTo: replyTo,
  );
  @override
  Future<Result<Uri>> attachmentUrl(String path) => live.attachmentUrl(path);
  @override
  Future<Result<Uint8List>> attachmentBytes(String path) =>
      live.attachmentBytes(path);
  @override
  Future<Result<void>> deleteForEveryone(Message message) =>
      live.deleteForEveryone(message);
  @override
  Future<Result<List<ReadMark>>> readMarks(String conversationId) =>
      live.readMarks(conversationId);
  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId) =>
      live.readUpdates(conversationId);
}

/// The overrides main.dart mounts, on [client]; only Google sign-in, the Play
/// update API, the photo picker and Firebase push -- nothing local to run
/// them on -- are fakes.
List<Override> _production(
  SupabaseClient client,
  String name, {
  ChatRepository? chat,
}) => [
  runtimeConfigProvider.overrideWithValue(
    const RuntimeConfig(
      supabaseUrl: _url,
      supabasePublishableKey: _key,
      googleWebClientId: 'c',
    ),
  ),
  authRepositoryProvider.overrideWithValue(_AccountAuth(client, name)),
  updateRepositoryProvider.overrideWithValue(FakeUpdate()),
  chatRepositoryProvider.overrideWithValue(
    chat ?? SupabaseChatRepository(client),
  ),
  presenceRepositoryProvider.overrideWithValue(
    SupabasePresenceRepository(client),
  ),
  profileRepositoryProvider.overrideWithValue(
    SupabaseProfileRepository(client),
  ),
  attachmentSourceProvider.overrideWithValue(PickerFake.cancels()),
  // Firebase push in main.dart: opening a chat clears its notification.
  // No token: shutDown() disposes the scope while the fake clock may still
  // hold PushRegistration's first registration, which then reads a disposed
  // Ref. Registration is not what this suite is about (see
  // push_display_integration_test.dart).
  pushSourceProvider.overrideWithValue(PushSourceFake(token: null)),
  pushRegistryProvider.overrideWithValue(PushRegistryFake()),
];

List<Conversation> _list(ProviderContainer c) =>
    c.read(conversationListProvider).value ?? const [];

Conversation? _row(ProviderContainer c, String id) =>
    _list(c).where((x) => x.id == id).firstOrNull;

/// The count the SERVER holds for [id], on a fresh read.
Future<int> _serverUnread(ChatRepository repo, String id) async {
  final r = await repo.conversations();
  expect(r, isA<Ok<List<Conversation>>>(), reason: 'the re-read failed');
  return (r as Ok<List<Conversation>>).value
      .firstWhere((c) => c.id == id)
      .unread;
}

Future<void> _markAllRead(ChatRepository repo) async {
  final r = await repo.conversations() as Ok<List<Conversation>>;
  for (final c in r.value.where((c) => c.unread > 0)) {
    expect(await repo.markRead(c.id), isA<Ok<void>>());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? unaClient;
  SupabaseClient? ottoClient;
  SupabaseClient? piaClient;
  SupabaseClient? deadClient;
  late SupabaseChatRepository una;
  late SupabaseChatRepository otto;
  late SupabaseChatRepository pia;
  late SupabaseChatRepository dead;
  late String unaId;
  late String ottoId;

  /// una <-> otto. The same row on every run: counts carry over, so each test
  /// sets its own baseline with markRead first.
  late String direct;

  /// una and otto; a new group each run.
  late String groupId;

  /// pia <-> otto: pia's own traffic, the positive control for her refusals.
  late String piaOtto;

  setUpAll(() async {
    unaClient = await _signedIn('una@integration.test');
    ottoClient = await _signedIn('otto@integration.test');
    piaClient = await _signedIn('pia@integration.test');
    deadClient = deadHostClient();
    una = SupabaseChatRepository(unaClient!);
    otto = SupabaseChatRepository(ottoClient!);
    pia = SupabaseChatRepository(piaClient!);
    dead = SupabaseChatRepository(deadClient!);
    unaId = unaClient!.auth.currentUser!.id;
    ottoId = ottoClient!.auth.currentUser!.id;

    direct = (await una.startDirectConversation(ottoId) as Ok<String>).value;
    piaOtto = (await pia.startDirectConversation(ottoId) as Ok<String>).value;
    groupId = (await una.startGroupConversation(
      title: _stamp('unread group'),
      memberIds: [ottoId],
    ) as Ok<String>).value;
    // The app's home is the list only after onboarding.
    await unaClient!
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', unaId);
  });

  tearDownAll(() async {
    await unaClient?.dispose();
    await ottoClient?.dispose();
    await piaClient?.dispose();
    await deadClient?.dispose();
  });

  group('SupabaseChatRepository', () {
    test('conversations().unread counts the other member\'s messages since '
        'the last read, never my own', () async {
      expect(await una.markRead(direct), isA<Ok<void>>());
      expect(await otto.markRead(direct), isA<Ok<void>>());
      expect(await _serverUnread(una, direct), 0);
      expect(await _serverUnread(otto, direct), 0);

      await otto.send(conversationId: direct, body: _stamp('o1'));
      await otto.send(conversationId: direct, body: _stamp('o2'));
      await una.send(conversationId: direct, body: _stamp('u1'));

      expect(await _serverUnread(una, direct), 2);
      expect(await _serverUnread(otto, direct), 1);
    });

    test('markRead clears only my count, only in that conversation', () async {
      expect(await una.markRead(groupId), isA<Ok<void>>());
      expect(await otto.markRead(direct), isA<Ok<void>>());
      await otto.send(conversationId: groupId, body: _stamp('g'));
      await otto.send(conversationId: direct, body: _stamp('d'));
      await una.send(conversationId: direct, body: _stamp('mine'));
      final unaBefore = await _serverUnread(una, direct);
      expect(unaBefore, greaterThan(0), reason: 'fixture: nothing to clear');

      expect(await una.markRead(direct), isA<Ok<void>>());

      expect(await _serverUnread(una, direct), 0);
      expect(
        await _serverUnread(una, groupId),
        1,
        reason: 'another one cleared',
      );
      expect(
        await _serverUnread(otto, direct),
        1,
        reason: "una's read moved otto's place",
      );
    });

    test(
      'a member not in the conversation is refused, and moves nothing',
      () async {
        expect(await otto.markRead(direct), isA<Ok<void>>());
        await una.send(conversationId: direct, body: _stamp('for otto'));
        // Positive control: pia can mark her own conversation.
        expect(await pia.markRead(piaOtto), isA<Ok<void>>());

        final refused = await pia.markRead(direct);
        expect(refused, isA<Err<void>>());
        expect((refused as Err<void>).failure, isA<DeniedFailure>());
        expect(await _serverUnread(otto, direct), 1);
        final hers = await pia.conversations() as Ok<List<Conversation>>;
        expect(hers.value.map((c) => c.id), isNot(contains(direct)));
      },
    );

    test('an unreachable server is an Err, not an exception', () async {
      final r = await dead.markRead(direct);
      expect(r, isA<Err<void>>());
      expect((r as Err<void>).failure.message, isNotEmpty);
    });

    test('last_read_at is not readable through the API', () async {
      final ok = await unaClient!
          .from('conversation_members')
          .select('conversation_id, user_id, joined_at')
          .eq('conversation_id', direct);
      expect(ok, hasLength(2));
      for (final column in ['last_read_at', '*']) {
        await expectLater(
          unaClient!
              .from('conversation_members')
              .select(column)
              .eq('conversation_id', direct),
          throwsA(
            isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
          ),
          reason: 'select $column exposed read positions',
        );
      }
    });
  });

  group('ConversationListController on the real stack', () {
    Future<ProviderContainer> liveList({ChatRepository? chat}) async {
      final c = ProviderContainer.test(
        overrides: _production(unaClient!, 'Una', chat: chat),
      );
      c.listen(conversationListProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      await c.read(conversationListProvider.future);
      return c;
    }

    test('a message from the other member bumps the count live, and the '
        'server agrees', () async {
      expect(await una.markRead(direct), isA<Ok<void>>());
      final c = await liveList();
      addTearDown(c.dispose);
      expect(_row(c, direct)!.unread, 0);

      final first = _stamp('one');
      await otto.send(conversationId: direct, body: first);
      await eventually<Conversation?>(
        () => _row(c, direct),
        (r) => r?.lastMessage == first,
        reason: 'the message never reached the list',
      );
      expect(_row(c, direct)!.unread, 1);

      final second = _stamp('two');
      await otto.send(conversationId: direct, body: second);
      await eventually<Conversation?>(
        () => _row(c, direct),
        (r) => r?.lastMessage == second,
      );
      expect(_row(c, direct)!.unread, 2);
      expect(
        await _serverUnread(una, direct),
        2,
        reason: 'live and server differ',
      );

      // My own message, from another device: previewed, never counted.
      final mine = _stamp('mine');
      await una.send(conversationId: direct, body: mine);
      await eventually<Conversation?>(
        () => _row(c, direct),
        (r) => r?.lastMessage == mine,
      );
      expect(_row(c, direct)!.unread, 2);
      expect(await _serverUnread(una, direct), 2);
    });

    test('markRead clears the row here and on the server', () async {
      expect(await otto.markRead(direct), isA<Ok<void>>());
      await otto.send(conversationId: direct, body: _stamp('x'));
      await una.send(conversationId: direct, body: _stamp('y'));
      final c = await liveList();
      addTearDown(c.dispose);
      expect(_row(c, direct)!.unread, greaterThan(0), reason: 'fixture');

      await c.read(conversationListProvider.notifier).markRead(direct);

      expect(_row(c, direct)!.unread, 0);
      expect(await _serverUnread(una, direct), 0);
      expect(await _serverUnread(otto, direct), 1, reason: "otto's moved");
    });

    test('the open conversation does not count', () async {
      expect(await una.markRead(direct), isA<Ok<void>>());
      final c = await liveList();
      addTearDown(c.dispose);
      c.read(openConversationProvider.notifier).open(direct);
      c.listen(messagesProvider, (_, _) {});
      await c.read(messagesProvider.future);
      // Every state the row passes through: the screen marks the message read
      // on the server, which would hide a count that went up and back down.
      final seen = <int>[];
      c.listen(conversationListProvider, (_, next) {
        final r = next.value?.where((x) => x.id == direct).firstOrNull;
        if (r != null) seen.add(r.unread);
      });

      final body = _stamp('while open');
      await otto.send(conversationId: direct, body: body);
      await eventually<Conversation?>(
        () => _row(c, direct),
        (r) => r?.lastMessage == body,
        reason: 'the list behind the screen never saw it',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(_row(c, direct)!.unread, 0);
      expect(seen, everyElement(0), reason: 'the open conversation counted');
    });

    test('markRead that cannot reach the server leaves the count', () async {
      await otto.send(conversationId: direct, body: _stamp('z'));
      final c = await liveList(chat: _MarkReadDown(una, dead));
      addTearDown(c.dispose);
      final before = _row(c, direct)!.unread;
      expect(before, greaterThan(0), reason: 'fixture');

      await c.read(conversationListProvider.notifier).markRead(direct);

      expect(_row(c, direct)!.unread, before, reason: 'cleared locally only');
      expect(c.read(conversationListProvider).hasError, isFalse);
      expect(await _serverUnread(una, direct), before);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('the list and message screens on the real stack', () {
    Widget app() => ProviderScope(
      overrides: _production(unaClient!, 'Una'),
      child: const SisApp(),
    );

    Future<void> until(WidgetTester t, bool Function() ok, String what) async {
      for (var i = 0; i < 150; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump();
        if (ok()) return;
      }
      fail('never happened: $what');
    }

    Future<void> tall(WidgetTester t) async {
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
    }

    Future<void> shutDown(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => unaClient!.removeAllChannels());
      // The socket was opened inside the test's fake clock; its heartbeat and
      // reconnect timers live there too. Close it, then let dart:io's 15 s
      // idle-connection timer and any heartbeat run out.
      await t.runAsync(() => unaClient!.realtime.disconnect());
      await t.pump(const Duration(seconds: 61));
    }

    /// Re-reads the server's count until it is 0 or time runs out.
    Future<int> serverSettlesAtZero(WidgetTester t) async {
      var server = -1;
      for (var i = 0; i < 50; i++) {
        server = (await t.runAsync(() => _serverUnread(una, direct)))!;
        if (server == 0) break;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await t.pump();
      }
      return server;
    }

    Finder tile(String id) => find.byKey(ValueKey('conversation-$id'));
    Finder badge(String id) => find.byKey(ValueKey('unread-$id'));

    testWidgets('an unread conversation shows its count, and opening it '
        'marks it read on the server', (t) async {
      await tall(t);
      await t.runAsync(() async {
        await _markAllRead(una);
        await otto.send(conversationId: direct, body: _stamp('before open'));
        await otto.send(conversationId: direct, body: _stamp('before open'));
      });
      await t.pumpWidget(app());
      await until(t, () => tile(direct).evaluate().isNotEmpty, 'the list');
      expect(
        find.descendant(
          of: badge(direct),
          matching: find.text('2'),
          matchRoot: true,
        ),
        findsOneWidget,
      );

      await t.tap(tile(direct));
      await until(
        t,
        () => find.byType(MessageScreen).evaluate().isNotEmpty,
        'the message screen',
      );
      expect(
        await serverSettlesAtZero(t),
        0,
        reason: 'opening did not mark it read on the server',
      );

      await t.pageBack();
      await until(t, () => badge(direct).evaluate().isEmpty, 'badge stayed');
      await shutDown(t);
    });

    testWidgets('while open, a message from the other member is marked read; '
        'after leaving, the list and the server agree', (t) async {
      await tall(t);
      await t.runAsync(() => _markAllRead(una));
      await t.pumpWidget(app());
      await until(t, () => tile(direct).evaluate().isNotEmpty, 'the list');
      expect(badge(direct), findsNothing);

      await t.tap(tile(direct));
      await until(
        t,
        () => find.byType(MessageScreen).evaluate().isNotEmpty,
        'the message screen',
      );
      // The screen subscribes before its first read, so a loaded history
      // means the subscription is live: otto's message must arrive as an
      // incoming one, not inside that first read.
      final container = ProviderScope.containerOf(
        t.element(find.byType(MessageScreen)),
      );
      await until(
        t,
        () => container.read(messagesProvider).hasValue,
        'the message screen never loaded',
      );

      final body = _stamp('while you look');
      await t.runAsync(() => otto.send(conversationId: direct, body: body));
      await until(
        t,
        () => find.text(body).evaluate().isNotEmpty,
        'the message never reached the open screen',
      );
      final server = await serverSettlesAtZero(t);
      expect(server, 0, reason: 'an incoming message left it unread');

      await t.pageBack();
      await until(
        t,
        () => find.byType(MessageScreen).evaluate().isEmpty,
        'the screen never closed',
      );
      await until(
        t,
        () => find
            .descendant(of: tile(direct), matching: find.textContaining(body))
            .evaluate()
            .isNotEmpty,
        'the list never showed the message',
      );
      expect(badge(direct), findsNothing);
      expect(await t.runAsync(() => _serverUnread(una, direct)), 0);
      await shutDown(t);
    });
  });
}
