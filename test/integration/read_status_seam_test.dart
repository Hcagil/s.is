@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
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
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/session_claim.dart';
import '../support/fakes.dart';
import '../support/dead_host.dart';
import '../support/reach.dart';

/// Read status on its seams, wired as main.dart wires it: the REAL
/// [ReadMarksController] over the real chat and profile repositories, the
/// real Realtime broadcast from `mark_read`, and the real list and message
/// screens -- plus the failure path of each of its connections (read marks,
/// read updates) on a real repository pointed at a dead host.
///
/// Requires a running local Supabase and the warmup probe; --concurrency=1.
/// Accounts sana, theo and wren are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
SupabaseClient _client([String url = _url]) => SupabaseClient(
  url,
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
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
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
  String? get userId => client.auth.currentUser?.id;
  @override
  String? get sessionId => sessionIdOf(client);
  @override
  Future<void> signOut() async {}
}

/// The real repository, with its read-status connections replaceable: by
/// the same calls on a real repository at a dead host (the connection that
/// fails is the real one), or by a slower real answer.
class _Wired implements ChatRepository {
  _Wired(this.live, {this.marks, this.updates, this.delivered});
  final ChatRepository live;
  final ChatRepository? marks;
  final ChatRepository? updates;
  final ChatRepository? delivered;

  @override
  Future<Result<void>> markDelivered(String conversationId, {DateTime? upTo}) =>
      (delivered ?? live).markDelivered(conversationId, upTo: upTo);

  @override
  Future<Result<Stream<ReadMark>>> deliveredUpdates(String conversationId) =>
      (delivered ?? live).deliveredUpdates(conversationId);

  /// Holds the real readMarks answer this long AFTER the server gave it:
  /// a slow network between the database and the phone.
  Duration answerLag = Duration.zero;

  @override
  Future<Result<List<ReadMark>>> readMarks(String id) async {
    final r = await (marks ?? live).readMarks(id);
    await Future<void>.delayed(answerLag);
    return r;
  }

  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String id) =>
      (updates ?? live).readUpdates(id);

  @override
  Future<Result<List<Member>>> members() => live.members();
  @override
  Future<Result<List<Conversation>>> conversations() => live.conversations();
  @override
  Future<Result<void>> markRead(String id) => live.markRead(id);
  @override
  Future<Result<List<Member>>> conversationMembers(String id) =>
      live.conversationMembers(id);
  @override
  Future<Result<List<GroupMember>>> groupRoster(String id) =>
      live.groupRoster(id);
  @override
  Future<Result<void>> leaveGroup(String id) => live.leaveGroup(id);
  @override
  Future<Result<void>> removeMember(String id, String memberId) =>
      live.removeMember(id, memberId);
  @override
  Future<Result<void>> addMembers(
    String id,
    List<String> memberIds, {
    required bool withHistory,
  }) => live.addMembers(id, memberIds, withHistory: withHistory);
  @override
  Future<Result<void>> setAdmin(
    String id,
    String memberId, {
    required bool isAdmin,
  }) => live.setAdmin(id, memberId, isAdmin: isAdmin);
  @override
  Future<Result<List<GroupEvent>>> groupEvents(String id) =>
      live.groupEvents(id);
  @override
  Future<Result<List<Message>>> sharedMedia(String id) => live.sharedMedia(id);
  @override
  Future<Result<List<Message>>> sharedLinks(String id) => live.sharedLinks(id);
  @override
  Future<Result<List<Message>>> messages(String id) => live.messages(id);

  @override
  Future<Result<Map<String, Uint8List>>> attachmentPreviews(List<String> ids) =>
      live.attachmentPreviews(ids);
  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String body,
    String? replyTo,
  }) => live.send(
    id: id,
    conversationId: conversationId,
    body: body,
    replyTo: replyTo,
  );
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
  Future<Result<void>> forward(Message message, List<String> ids) =>
      live.forward(message, ids);
  @override
  Future<Result<Uri>> attachmentUrl(String path) => live.attachmentUrl(path);
  @override
  Future<Result<Uint8List>> attachmentBytes(String path) =>
      live.attachmentBytes(path);
  @override
  Future<Result<Uint8List>> avatarBytes(String path) => live.avatarBytes(path);
  @override
  Future<Result<void>> setGroupAvatar(
    String conversationId,
    PickedImage? image, {
    String? previousPath,
  }) => live.setGroupAvatar(conversationId, image, previousPath: previousPath);
  @override
  Future<Result<void>> hideForMe(Message m) => live.hideForMe(m);
  @override
  Future<Result<int>> unreadTotal() => live.unreadTotal();
  @override
  Future<Result<void>> deleteForEveryone(Message message) =>
      live.deleteForEveryone(message);

  @override
  Future<Result<Message>> editMessage(Message message, String body) =>
      live.editMessage(message, body);
  @override
  Future<Result<List<Message>>> search(
    String query, {
    String? conversationId,
  }) => live.search(query, conversationId: conversationId);
  @override
  Future<Result<List<Message>>> messagesAround(String id, Message anchor) =>
      live.messagesAround(id, anchor);
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
  // The device's push channel (Firebase in main.dart): opening a chat clears
  // its notification through it. Not what this suite is about.
  pushSourceProvider.overrideWithValue(PushSourceFake()),
  pushRegistryProvider.overrideWithValue(PushRegistryFake()),
];

ReadMark? _markOf(ProviderContainer c, String userId) => c
    .read(readMarksProvider)
    .value
    ?.where((m) => m.userId == userId)
    .firstOrNull;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient sanaClient;
  late SupabaseClient theoClient;
  late SupabaseClient wrenClient;
  late SupabaseClient deadClient;
  late SupabaseChatRepository sana;
  late SupabaseChatRepository theo;
  late SupabaseChatRepository wren;
  late SupabaseChatRepository dead;
  late String sanaId;
  late String theoId;
  late String wrenId;

  /// sana <-> theo.
  late String direct;

  /// sana, theo and wren; a new group each run.
  late String club;

  Future<void> share(SupabaseClient c, bool on) async {
    final r = await SupabaseProfileRepository(c).save(shareReadStatus: on);
    expect(r, isA<Ok<OwnProfile>>(), reason: 'could not set read status');
  }

  setUpAll(() async {
    sanaClient = await _signedIn('sana@integration.test');
    theoClient = await _signedIn('theo@integration.test');
    wrenClient = await _signedIn('wren@integration.test');
    deadClient = deadHostClient();
    sana = SupabaseChatRepository(sanaClient);
    theo = SupabaseChatRepository(theoClient);
    wren = SupabaseChatRepository(wrenClient);
    dead = SupabaseChatRepository(deadClient);
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;
    wrenId = wrenClient.auth.currentUser!.id;
    await findByTag(sanaClient, [theoClient, wrenClient]);
    direct = (await sana.startDirectConversation(theoId) as Ok<String>).value;
    club = (await sana.startGroupConversation(
      title: _stamp('reads club'),
      memberIds: [theoId, wrenId],
    ) as Ok<String>).value;
    // The app's home is the list only after onboarding.
    await sanaClient
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', sanaId);
  });

  setUp(() async {
    for (final c in [sanaClient, theoClient, wrenClient]) {
      await share(c, true);
    }
  });

  tearDownAll(() async {
    for (final c in [sanaClient, theoClient, wrenClient, deadClient]) {
      await c.dispose();
    }
  });

  group('ReadMarksController on the real stack', () {
    /// Polls until [ok]; Realtime has no callback to wait on here.
    Future<void> eventually(
      bool Function() ok,
      String what, {
      Duration within = const Duration(seconds: 30),
      Future<void> Function()? meanwhile,
    }) async {
      final deadline = DateTime.now().add(within);
      while (DateTime.now().isBefore(deadline)) {
        if (ok()) return;
        await meanwhile?.call();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      fail('never happened within $within: $what');
    }

    Future<ProviderContainer> opened(String id, {ChatRepository? chat}) async {
      final c = ProviderContainer.test(
        overrides: _production(sanaClient, 'Sana', chat: chat),
      );
      addTearDown(() async {
        c.dispose();
        await sanaClient.removeAllChannels();
      });
      await settled(c);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);
      c.read(openConversationProvider.notifier).open(id);
      c.listen(readMarksProvider, (_, _) {});
      await c.read(readMarksProvider.future);
      return c;
    }

    Future<Message> sent(String id) async {
      final r = await sana.send(
        id: randomMessageId(),
        conversationId: id,
        body: _stamp('mine'),
      );
      return (r as Ok<Message>).value;
    }

    test('the other member reading my message reaches the open '
        'conversation live', () async {
      final c = await opened(direct);
      expect(_markOf(c, theoId)?.shares, isTrue, reason: 'both share');
      final message = await sent(direct);
      expect(
        deliveryOf(message, c.read(readMarksProvider).requireValue),
        isNot(Delivery.read),
        reason: 'fixture: theo has not read it yet',
      );

      await eventually(
        () => _markOf(c, theoId)?.hasRead(message.createdAt) ?? false,
        "theo's read to arrive",
        meanwhile: () => theo.markRead(direct),
      );
      expect(
        deliveryOf(message, c.read(readMarksProvider).requireValue),
        Delivery.read,
      );
    }, timeout: const Timeout(Duration(minutes: 1)));

    test(
      'a read made while the first load is on its way is not lost',
      () async {
        final message = await sent(direct);
        final wired = _Wired(sana)..answerLag = const Duration(seconds: 4);
        final c = ProviderContainer.test(
          overrides: _production(sanaClient, 'Sana', chat: wired),
        );
        addTearDown(() async {
          c.dispose();
          await sanaClient.removeAllChannels();
        });
        await settled(c);
        c.listen(ownProfileProvider, (_, _) {});
        await c.read(ownProfileProvider.future);
        c.read(openConversationProvider.notifier).open(direct);
        c.listen(readMarksProvider, (_, _) {});

        // The server has answered "not read yet"; the answer is on its way.
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(await theo.markRead(direct), isA<Ok<void>>());
        await c.read(readMarksProvider.future);

        await eventually(
          () => _markOf(c, theoId)?.hasRead(message.createdAt) ?? false,
          'the read made during the load to show',
          within: const Duration(seconds: 15),
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test('my own switch, through the real profile: off hides reads at once '
        'and stops them arriving; on brings both back', () async {
      final c = await opened(direct);
      final profile = c.read(ownProfileProvider.notifier);

      expect(
        await profile.setSharing(readStatus: false),
        isA<Ok<OwnProfile>>(),
      );
      await eventually(
        () => c.read(readMarksProvider).value?.every((m) => !m.shares) ?? false,
        'reads hidden after turning mine off',
      );
      final message = await sent(direct);
      for (var i = 0; i < 4; i++) {
        await theo.markRead(direct);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(
        _markOf(c, theoId)?.readAt,
        isNull,
        reason: 'a read reached me while I do not share',
      );

      expect(await profile.setSharing(readStatus: true), isA<Ok<OwnProfile>>());
      await eventually(
        () => _markOf(c, theoId)?.shares ?? false,
        'reads shown again after turning mine on',
      );
      final next = await sent(direct);
      expect(
        message.createdAt.isAfter(next.createdAt),
        isFalse,
        reason: 'fixture',
      );
      await eventually(
        () => _markOf(c, theoId)?.hasRead(next.createdAt) ?? false,
        'reads arriving live again after turning mine on',
        meanwhile: () => theo.markRead(direct),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the other member hiding theirs: his reading shows as two grey, never '
        'blue', () async {
      await share(theoClient, false);
      final c = await opened(direct);
      final message = await sent(direct);

      expect(_markOf(c, theoId)?.shares, isFalse);
      Delivery now() =>
          deliveryOf(message, c.read(readMarksProvider).requireValue);
      expect(now(), Delivery.sent);
      await eventually(
        () => now() == Delivery.delivered,
        'his read to arrive as a delivery',
        meanwhile: () => theo.markRead(direct),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(now(), Delivery.delivered, reason: 'turned blue');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test(
      'read marks unreachable: an error state, the messages still load',
      () async {
        final c = ProviderContainer.test(
          overrides: _production(
            sanaClient,
            'Sana',
            chat: _Wired(sana, marks: dead, updates: dead),
          ),
        );
        addTearDown(() async {
          c.dispose();
          await sanaClient.removeAllChannels();
        });
        await settled(c);
        c.read(openConversationProvider.notifier).open(direct);
        c.listen(readMarksProvider, (_, _) {});
        c.listen(messagesProvider, (_, _) {});

        await expectLater(c.read(readMarksProvider.future), throwsA(anything));
        expect(await c.read(messagesProvider.future), isNotEmpty);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('read updates unreachable: what was loaded still shows', () async {
      expect(await theo.markRead(direct), isA<Ok<void>>());
      final c = await opened(direct, chat: _Wired(sana, updates: dead));

      expect(c.read(readMarksProvider).hasError, isFalse);
      expect(_markOf(c, theoId)?.readAt, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test("theo's delivery reaches the open conversation live, and leaves "
        'his read alone', () async {
      expect(await theo.markRead(direct), isA<Ok<void>>());
      final c = await opened(direct);
      final readBefore = _markOf(c, theoId)?.readAt;
      expect(readBefore, isNotNull, reason: 'fixture');
      final message = await sent(direct);
      expect(
        _markOf(c, theoId)?.hasDelivered(message.createdAt),
        isFalse,
        reason: 'fixture: not delivered yet',
      );
      await eventually(
        () => _markOf(c, theoId)?.hasDelivered(message.createdAt) ?? false,
        "theo's delivery to arrive",
        meanwhile: () => theo.markDelivered(direct),
      );
      final m = _markOf(c, theoId)!;
      expect(m.shares, isTrue, reason: 'the delivery event replaced the mark');
      expect(m.readAt, readBefore, reason: 'the delivery event moved readAt');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('delivery updates unreachable (join fails): the marks still load, '
        'with deliveredAt, and reads still arrive', () async {
      expect(await theo.markDelivered(direct), isA<Ok<void>>());
      final c = await opened(direct, chat: _Wired(sana, delivered: dead));
      expect(c.read(readMarksProvider).hasError, isFalse);
      expect(_markOf(c, theoId)?.deliveredAt, isNotNull);

      final message = await sent(direct);
      await eventually(
        () => _markOf(c, theoId)?.hasRead(message.createdAt) ?? false,
        "theo's read to arrive without the delivery channel",
        meanwhile: () => theo.markRead(direct),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('the message screen on the real stack', () {
    Widget app({ChatRepository? chat}) => ProviderScope(
      overrides: _production(sanaClient, 'Sana', chat: chat),
      child: const SisApp(),
    );

    Future<void> until(
      WidgetTester t,
      bool Function() ok,
      String what, {
      Future<void> Function()? meanwhile,
    }) async {
      for (var i = 0; i < 200; i++) {
        if (i % 10 == 0 && meanwhile != null) await t.runAsync(meanwhile);
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        // Advances the test clock too, so a route transition finishes.
        await t.pump(const Duration(milliseconds: 150));
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
      await t.runAsync(() => sanaClient.removeAllChannels());
      await t.runAsync(() => sanaClient.realtime.disconnect());
      await t.pump(const Duration(seconds: 61));
    }

    Finder tile(String id) => find.byKey(ValueKey('conversation-$id'));
    Finder bubble(String id) => find.byKey(ValueKey('message-$id'));

    /// The state my bubble's tick shows (`tick-<id>`, a DeliveryTick).
    Delivery? tick(WidgetTester t, String id) {
      final f = find.byKey(ValueKey('tick-$id'));
      return f.evaluate().isEmpty ? null : t.widget<DeliveryTick>(f).delivery;
    }

    Future<Message> openWithMine(
      WidgetTester t,
      String id, {
      ChatRepository? chat,
    }) async {
      await tall(t);
      final sent = await t.runAsync(
        () => sana.send(
          id: randomMessageId(),
          conversationId: id,
          body: _stamp('mine'),
        ),
      );
      final message = (sent! as Ok<Message>).value;
      await t.pumpWidget(app(chat: chat));
      await until(t, () => tile(id).evaluate().isNotEmpty, 'the list');
      await t.tap(tile(id));
      await until(
        t,
        () => bubble(message.id).evaluate().isNotEmpty,
        'my message on the open screen',
      );
      return message;
    }

    testWidgets('1:1: one tick until theo has it, two grey once it reaches '
        'him, two blue once he reads it, live', (t) async {
      try {
        final message = await openWithMine(t, direct);
        await until(
          t,
          () => tick(t, message.id) == Delivery.sent,
          'one tick before theo has it',
        );

        await until(
          t,
          () => tick(t, message.id) == Delivery.delivered,
          'two grey once it reached theo',
          meanwhile: () => theo.markDelivered(direct),
        );

        await until(
          t,
          () => tick(t, message.id) == Delivery.read,
          'two blue once theo has read it',
          meanwhile: () => theo.markRead(direct),
        );
      } finally {
        await shutDown(t);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('group: blue only once EVERY member has read it, two grey '
        'once it reached every member; both are its readers', (t) async {
      try {
        final message = await openWithMine(t, club);
        await until(
          t,
          () => tick(t, message.id) == Delivery.sent,
          'one tick before anyone has it',
        );

        final container = ProviderScope.containerOf(
          t.element(find.byType(MessageScreen)),
        );
        // theo reads it; wren has not even received it: still one tick.
        await until(
          t,
          () => _markOf(container, theoId)?.hasRead(message.createdAt) ?? false,
          "theo's read to arrive",
          meanwhile: () => theo.markRead(club),
        );
        expect(
          tick(t, message.id),
          Delivery.sent,
          reason: 'one reader of two turned it read/delivered',
        );

        await until(
          t,
          () => tick(t, message.id) == Delivery.delivered,
          'two grey once it reached wren too',
          meanwhile: () => wren.markDelivered(club),
        );
        expect(
          _markOf(container, wrenId)?.hasRead(message.createdAt),
          isFalse,
          reason: 'fixture: wren shares and has not read it yet',
        );

        await until(
          t,
          () => _markOf(container, wrenId)?.hasRead(message.createdAt) ?? false,
          "wren's read to arrive",
          meanwhile: () => wren.markRead(club),
        );
        await until(
          t,
          () => tick(t, message.id) == Delivery.read,
          'two blue once every member has read it',
        );

        // The readers, as the slice-7 readers card will list them: both,
        // from the live marks the screen holds (the old "Read by" sheet left
        // the action set with reactions).
        final readers = readersOf(
          container.read(readMarksProvider).value!,
          message.createdAt,
        );
        expect(readers.map((m) => m.userId).toSet(), {theoId, wrenId});
        expect(
          readers.first.readAt!.isAfter(readers.last.readAt!),
          isFalse,
          reason: 'earliest reader first',
        );
      } finally {
        await shutDown(t);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('read status unreachable: the conversation still opens and, '
        'once the connection has failed, my message shows one tick', (t) async {
      try {
        final message = await openWithMine(
          t,
          direct,
          chat: _Wired(sana, marks: dead, updates: dead),
        );
        final container = ProviderScope.containerOf(
          t.element(find.byType(MessageScreen)),
        );
        await until(
          t,
          () => container.read(readMarksProvider).hasError,
          'the read-status connection to fail',
        );
        expect(bubble(message.id), findsOneWidget);
        expect(tick(t, message.id), Delivery.sent);
      } finally {
        await shutDown(t);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // 0.30.5, owner report (TestFlight): iOS suspends the socket the moment
  // the app is backgrounded and Realtime replays nothing. The resume
  // catch-up (resumeCatchUpProvider) must re-read read marks and mark the
  // open chat read -- against the real database, not a fake's idea of it.
  group('resume catch-up on the real stack', () {
    Future<void> eventually(
      Future<bool> Function() ok,
      String what, {
      Duration within = const Duration(seconds: 20),
    }) async {
      final deadline = DateTime.now().add(within);
      while (DateTime.now().isBefore(deadline)) {
        if (await ok()) return;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      fail('never happened within $within: $what');
    }

    Future<ProviderContainer> sanaIn(String id, {ChatRepository? chat}) async {
      final c = ProviderContainer.test(
        overrides: _production(sanaClient, 'Sana', chat: chat),
      );
      addTearDown(() async {
        c.dispose();
        await sanaClient.removeAllChannels();
      });
      await settled(c);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      c.read(openConversationProvider.notifier).open(id);
      c.listen(messagesProvider, (_, _) {});
      c.listen(readMarksProvider, (_, _) {});
      await c.read(messagesProvider.future);
      await c.read(readMarksProvider.future);
      return c;
    }

    Future<DateTime?> theoSeesSanaReadAt() async {
      final r = await theo.readMarks(direct);
      return (r as Ok<List<ReadMark>>).value
          .where((m) => m.userId == sanaId)
          .firstOrNull
          ?.readAt;
    }

    test(
      'a read whose broadcast this phone missed shows after resume',
      () async {
        // The reads:<id> channel is the one that died: its join goes to a
        // dead host, so nothing arrives live -- as with a suspended socket.
        final c = await sanaIn(direct, chat: _Wired(sana, updates: dead));
        final mine = (await sana.send(
          id: randomMessageId(),
          conversationId: direct,
          body: _stamp('mine'),
        ) as Ok<Message>).value;
        expect(await theo.markRead(direct), isA<Ok<void>>());
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(
          _markOf(c, theoId)?.hasRead(mine.createdAt) ?? false,
          isFalse,
          reason: 'fixture: the read arrived live',
        );

        c.read(resumeCatchUpProvider)();

        await eventually(
          () async => _markOf(c, theoId)?.hasRead(mine.createdAt) ?? false,
          "theo's read to show after resume",
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('a message arriving while hidden is not marked read; after '
        'resume the server holds the read', () async {
      final c = await sanaIn(direct);
      c.read(appVisibleProvider.notifier).set(false);
      final before = await theoSeesSanaReadAt();

      final theirs = (await theo.send(
        id: randomMessageId(),
        conversationId: direct,
        body: _stamp('while hidden'),
      ) as Ok<Message>).value;
      await eventually(
        () async =>
            c.read(messagesProvider).value?.any((m) => m.id == theirs.id) ??
            false,
        'the message to arrive live while hidden',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      final hidden = await theoSeesSanaReadAt();
      expect(
        hidden != null && !hidden.isBefore(theirs.createdAt),
        isFalse,
        reason: 'marked read while hidden (before: $before, now: $hidden)',
      );

      c.read(appVisibleProvider.notifier).set(true);
      c.read(resumeCatchUpProvider)();

      await eventually(() async {
        final at = await theoSeesSanaReadAt();
        return at != null && !at.isBefore(theirs.createdAt);
      }, 'the server to record the read after resume');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
