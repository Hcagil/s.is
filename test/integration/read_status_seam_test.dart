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
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/presence/domain/last_seen.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';

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
const _deadUrl = 'http://127.0.0.1:1';

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
  Future<void> signOut() async {}
}

/// The real repository, with its read-status connections replaceable: by
/// the same calls on a real repository at a dead host (the connection that
/// fails is the real one), or by a slower real answer.
class _Wired implements ChatRepository {
  _Wired(this.live, {this.marks, this.updates});
  final ChatRepository live;
  final ChatRepository? marks;
  final ChatRepository? updates;

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
  Future<Result<void>> deleteForEveryone(Message message) =>
      live.deleteForEveryone(message);
}

/// The overrides main.dart mounts, on [client]; only Google sign-in, the Play
/// update API and the photo picker -- nothing local to run them on -- are
/// fakes.
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
    deadClient = _client(_deadUrl);
    sana = SupabaseChatRepository(sanaClient);
    theo = SupabaseChatRepository(theoClient);
    wren = SupabaseChatRepository(wrenClient);
    dead = SupabaseChatRepository(deadClient);
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;
    wrenId = wrenClient.auth.currentUser!.id;
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
      final r = await sana.send(conversationId: id, body: _stamp('mine'));
      return (r as Ok<Message>).value;
    }

    test('the other member reading my message reaches the open '
        'conversation live', () async {
      final c = await opened(direct);
      expect(_markOf(c, theoId)?.shares, isTrue, reason: 'both share');
      final message = await sent(direct);
      expect(
        isReadByAnyone(
          c.read(readMarksProvider).requireValue,
          message.createdAt,
        ),
        isFalse,
        reason: 'fixture: theo has not read it yet',
      );

      await eventually(
        () => _markOf(c, theoId)?.hasRead(message.createdAt) ?? false,
        "theo's read to arrive",
        meanwhile: () => theo.markRead(direct),
      );
      expect(
        isReadByAnyone(
          c.read(readMarksProvider).requireValue,
          message.createdAt,
        ),
        isTrue,
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

    test(
      'the other member hiding theirs makes my messages simply normal',
      () async {
        await share(theoClient, false);
        final c = await opened(direct);
        final message = await sent(direct);

        expect(_markOf(c, theoId)?.shares, isFalse);
        expect(
          isReadByAnyone(
            c.read(readMarksProvider).requireValue,
            message.createdAt,
          ),
          isTrue,
          reason: 'nothing shared: the message looks normal',
        );
      },
    );

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

    /// Whether the bubble has the yellow unread edge: the outermost
    /// decoration at `ValueKey('message-$id')` bordered in 0xFFFFD54F.
    bool yellow(WidgetTester t, String id) {
      final box =
          find
                  .descendant(
                    of: bubble(id),
                    matching: find.byType(DecoratedBox),
                    matchRoot: true,
                  )
                  .evaluate()
                  .first
                  .widget
              as DecoratedBox;
      final border = (box.decoration as BoxDecoration).border as Border?;
      return border != null &&
          [
            border.top,
            border.right,
            border.bottom,
            border.left,
          ].every((s) => s.color == const Color(0xFFFFD54F));
    }

    Future<Message> openWithMine(
      WidgetTester t,
      String id, {
      ChatRepository? chat,
    }) async {
      await tall(t);
      final sent = await t.runAsync(
        () => sana.send(conversationId: id, body: _stamp('mine')),
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

    testWidgets('1:1: my message has the yellow edge until theo reads it, '
        'then none, live', (t) async {
      try {
        final message = await openWithMine(t, direct);
        await until(
          t,
          () => yellow(t, message.id),
          'yellow edge before theo reads',
        );

        await until(
          t,
          () => !yellow(t, message.id),
          'normal once theo has read it',
          meanwhile: () => theo.markRead(direct),
        );
      } finally {
        await shutDown(t);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('group: yellow edge until the first sharer reads it; "Read '
        'by" names every reader, with when', (t) async {
      try {
        final names = {
          for (final m in (await t.runAsync(
            () => sana.conversationMembers(club),
          ) as Ok<List<Member>>).value)
            m.userId: m.displayName,
        };
        final message = await openWithMine(t, club);
        await until(
          t,
          () => yellow(t, message.id),
          'yellow edge before anyone reads',
        );

        // theo alone is enough, though wren shares and has not read it.
        await until(
          t,
          () => !yellow(t, message.id),
          'read once theo has read it',
          meanwhile: () => theo.markRead(club),
        );
        final container = ProviderScope.containerOf(
          t.element(find.byType(MessageScreen)),
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
        expect(yellow(t, message.id), isFalse);

        await t.longPress(bubble(message.id));
        await t.pumpAndSettle();
        await t.tap(find.text('Read by'));
        await t.pumpAndSettle();
        final now = DateTime.now();
        for (final id in [theoId, wrenId]) {
          expect(find.text(names[id]!), findsWidgets, reason: 'reader $id');
          final at = _markOf(container, id)!.readAt!;
          expect(find.text(lastSeenLabel(at, now)), findsWidgets);
        }
        expect(find.text('Nobody yet'), findsNothing);
      } finally {
        await shutDown(t);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('read status unreachable: the conversation still opens and, '
        'once the connection has failed, my message looks normal', (t) async {
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
        expect(yellow(t, message.id), isFalse);
      } finally {
        await shutDown(t);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
