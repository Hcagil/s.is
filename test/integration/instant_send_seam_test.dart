@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
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
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/reach.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../support/video_fakes.dart';

/// A text message shown the moment it is sent (2026-09-28), on the sender's
/// own MessageScreen over the real [SupabaseChatRepository]: the server's
/// row and its real Realtime echo must end as exactly one bubble, whichever
/// arrives first; a send the server never receives waits, queued with its
/// clock, and goes by itself under the same id once the connection is back;
/// and a send whose answer is lost after the row landed is read back as
/// ours on the retry -- one bubble, one row, every time.
///
/// The repository is the real one, relayed so the test can (a) see what the
/// screen's own subscription delivers, (b) hold the real answer until the
/// real echo has reached the screen, and (c) send through a client whose
/// host is dead while the screen itself was loaded live -- the member going
/// offline with the chat open. Auth and presence are fakes, as in every
/// seam test (docs/ARCHITECTURE.md).
///
/// Requires `docker compose run --rm supabase start`. Uses umut and zane
/// (supabase/seed.sql); run with --concurrency=1, after
/// test/integration/realtime_warmup_test.dart.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

typedef _Send = Future<Result<Message>> Function({
  required String id,
  required String conversationId,
  required String body,
  String? replyTo,
});

/// The real repository, passed through untouched except where noted.
class _Relay implements ChatRepository {
  // Slice 5a signatures only (delivery marks); no behaviour.
  @override
  Future<Result<void>> markDelivered(
    String conversationId, {
    DateTime? upTo,
  }) async => const Ok(null);

  @override
  Future<Result<Stream<ReadMark>>> deliveredUpdates(
    String conversationId,
  ) async => const Ok(Stream<ReadMark>.empty());
  _Relay(this.real);
  final ChatRepository real;

  /// Where [send] goes; the real repository unless a test says otherwise.
  _Send? sendVia;

  /// Ids of every message the screen's own subscription delivered.
  final echoed = <String>[];

  /// Every answer [send] returned, in order.
  final answers = <Result<Message>>[];

  /// The id of every send the screen asked for, in order -- a retry
  /// repeats one.
  final ids = <String>[];

  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String body,
    String? replyTo,
  }) async {
    ids.add(id);
    final r = await (sendVia ?? real.send)(
      id: id,
      conversationId: conversationId,
      body: body,
      replyTo: replyTo,
    );
    answers.add(r);
    return r;
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
    final r = await real.incoming(conversationId);
    if (r case Ok(:final value)) {
      return Ok(
        value.map((m) {
          echoed.add(m.id);
          return m;
        }),
      );
    }
    return r;
  }

  @override
  Future<Result<List<Member>>> members() => real.members();
  @override
  Future<Result<List<Conversation>>> conversations() => real.conversations();
  @override
  Future<Result<void>> markRead(String id) => real.markRead(id);
  @override
  Future<Result<List<Member>>> conversationMembers(String id) =>
      real.conversationMembers(id);
  @override
  Future<Result<List<GroupMember>>> groupRoster(String id) =>
      real.groupRoster(id);
  @override
  Future<Result<void>> leaveGroup(String id) => real.leaveGroup(id);
  @override
  Future<Result<void>> removeMember(String id, String memberId) =>
      real.removeMember(id, memberId);
  @override
  Future<Result<void>> addMembers(
    String id,
    List<String> memberIds, {
    required bool withHistory,
  }) => real.addMembers(id, memberIds, withHistory: withHistory);
  @override
  Future<Result<void>> setAdmin(
    String id,
    String memberId, {
    required bool isAdmin,
  }) => real.setAdmin(id, memberId, isAdmin: isAdmin);
  @override
  Future<Result<List<GroupEvent>>> groupEvents(String id) =>
      real.groupEvents(id);
  @override
  Future<Result<List<Message>>> sharedMedia(String id) => real.sharedMedia(id);
  @override
  Future<Result<List<Message>>> sharedLinks(String id) => real.sharedLinks(id);
  @override
  Future<Result<List<Message>>> messages(String id) => real.messages(id);

  @override
  Future<Result<Map<String, Uint8List>>> attachmentPreviews(List<String> ids) =>
      real.attachmentPreviews(ids);
  @override
  Future<Result<Stream<Message>>> incomingAll() => real.incomingAll();
  @override
  Future<Result<String>> startDirectConversation(String other) =>
      real.startDirectConversation(other);
  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) => real.startGroupConversation(title: title, memberIds: memberIds);
  @override
  Future<Result<void>> setGroupAvatar(
    String id,
    PickedImage? image, {
    String? previousPath,
  }) => real.setGroupAvatar(id, image, previousPath: previousPath);
  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) => real.sendImage(
    conversationId: conversationId,
    image: image,
    body: body,
    replyTo: replyTo,
  );
  @override
  Future<Result<void>> forward(Message m, List<String> ids) =>
      real.forward(m, ids);
  @override
  Future<Result<Uri>> attachmentUrl(String path) => real.attachmentUrl(path);
  @override
  Future<Result<Uint8List>> attachmentBytes(String path) =>
      real.attachmentBytes(path);
  @override
  Future<Result<Uint8List>> avatarBytes(String path) => real.avatarBytes(path);
  @override
  Future<Result<List<ReadMark>>> readMarks(String id) => real.readMarks(id);
  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String id) =>
      real.readUpdates(id);
  @override
  Future<Result<void>> hideForMe(Message m) => real.hideForMe(m);
  @override
  Future<Result<int>> unreadTotal() => real.unreadTotal();
  @override
  Future<Result<void>> deleteForEveryone(Message m) =>
      real.deleteForEveryone(m);
  @override
  Future<Result<Message>> editMessage(Message m, String body) =>
      real.editMessage(m, body);
  @override
  Future<Result<List<Message>>> search(String q, {String? conversationId}) =>
      real.search(q, conversationId: conversationId);
  @override
  Future<Result<List<Message>>> messagesAround(String id, Message anchor) =>
      real.messagesAround(id, anchor);
}

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
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

void main() {
  // Real timers: a real Realtime echo and real round trips.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient umutClient, zaneClient;
  late Member umut;
  late String conversationId;

  setUpAll(() async {
    umutClient = await _signedIn('umut@integration.test');
    zaneClient = await _signedIn('zane@integration.test');
    umut = Member(userId: umutClient.auth.currentUser!.id, displayName: 'Umut');
    await findByTag(umutClient, [zaneClient]);
    final started = await SupabaseChatRepository(umutClient)
        .startDirectConversation(zaneClient.auth.currentUser!.id);
    conversationId = (started as Ok<String>).value;
  });

  tearDownAll(() async {
    await umutClient.dispose();
    await zaneClient.dispose();
  });

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 300; i++) {
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    fail('never happened: $what');
  }

  final field = find.byKey(const ValueKey('composer-field'));
  final send = find.byKey(const ValueKey('composer-send'));

  /// Bubbles of messages still waiting in a send queue: a pending bubble
  /// is keyed by the same id the server stores it under.
  Finder pendingIn(ProviderContainer c) {
    final queued = {
      for (final q in c.read(sendQueueProvider).values)
        for (final m in q) m.id,
    };
    return find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          k.value.startsWith('message-') &&
          queued.contains(k.value.substring('message-'.length));
    });
  }

  // The pending tick (Update 1 slice 5: the clock is a DeliveryTick state).
  final clock = find.byWidgetPredicate(
    (w) => w is DeliveryTick && w.delivery == Delivery.pending,
  );

  String composerText(WidgetTester t) => t
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .controller
      .text;

  /// Umut's screen over [relay], wired as main.dart wires it, loaded live.
  Future<ProviderContainer> mount(WidgetTester t, _Relay relay) async {
    final c = ProviderContainer(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(relay),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(umut)),
      ],
    );
    await t.runAsync(() => settled(c));
    c.read(openConversationProvider.notifier).open(conversationId);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: sisTheme(Brightness.light),
          home: const MessageScreen(title: 'Zane'),
        ),
      ),
    );
    await until(
      t,
      () => c.read(messagesProvider).hasValue && field.evaluate().isNotEmpty,
      'the conversation to load',
    );
    return c;
  }

  Future<void> unmount(WidgetTester t, ProviderContainer c) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
    await t.runAsync(() => umutClient.removeAllChannels());
  }

  Future<List<dynamic>> rowsWithBody(WidgetTester t, String body) async =>
      (await t.runAsync(
        () => umutClient
            .from('messages')
            .select('id')
            .eq('conversation_id', conversationId)
            .eq('body', body),
      ))!;

  /// Sends [body] through the composer and waits until the screen holds the
  /// server's row and the screen's own subscription has delivered its echo.
  Future<Message> sendAndAwaitEcho(
    WidgetTester t,
    ProviderContainer c,
    _Relay relay,
    String body,
  ) async {
    await t.enterText(field, body);
    await t.pump();
    await t.tap(send);
    await t.pump();
    await until(t, () => relay.answers.isNotEmpty, 'the server to answer');
    final stored = (relay.answers.single as Ok<Message>).value;
    await until(
      t,
      () => relay.echoed.contains(stored.id),
      'the real Realtime echo of ${stored.id} to reach the screen',
    );
    // A few more frames for anything the echo would still change.
    for (var i = 0; i < 5; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    return stored;
  }

  void expectShownOnce(WidgetTester t, ProviderContainer c, Message stored) {
    final held = c.read(messagesProvider).requireValue;
    expect(held.where((m) => m.id == stored.id), hasLength(1));
    expect(held.where((m) => m.sending), isEmpty);
    expect(find.byKey(ValueKey('message-${stored.id}')), findsOneWidget);
    expect(pendingIn(c), findsNothing);
    expect(clock, findsNothing);
  }

  testWidgets('the answer first, then the real echo: one bubble', (t) async {
    final relay = _Relay(SupabaseChatRepository(umutClient));
    final c = await mount(t, relay);
    final body = 'instant ${DateTime.now().microsecondsSinceEpoch}';

    final stored = await sendAndAwaitEcho(t, c, relay, body);

    expect(stored.body, body);
    expectShownOnce(t, c, stored);
    expect(await rowsWithBody(t, body), hasLength(1));
    await unmount(t, c);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('the real echo first, then the answer: one bubble', (t) async {
    final relay = _Relay(SupabaseChatRepository(umutClient));
    var echoCameFirst = false;
    relay.sendVia =
        ({required id, required conversationId, required body, replyTo}) async {
          final r = await relay.real.send(
            id: id,
            conversationId: conversationId,
            body: body,
            replyTo: replyTo,
          );
          if (r case Ok(:final value)) {
            // Hold the real answer until the real echo reached the screen.
            for (var i = 0; i < 300 && !relay.echoed.contains(value.id); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            echoCameFirst = relay.echoed.contains(value.id);
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          return r;
        };
    final c = await mount(t, relay);
    final body = 'instant echo-first ${DateTime.now().microsecondsSinceEpoch}';

    final stored = await sendAndAwaitEcho(t, c, relay, body);

    expect(echoCameFirst, isTrue, reason: 'the order under test did happen');
    expectShownOnce(t, c, stored);
    await unmount(t, c);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('offline with the chat open: the message waits with its clock '
      'and no notice; back online it sends by itself, retried under the same '
      'id, stored once', (t) async {
    final dead = SupabaseChatRepository(
      (await t.runAsync(() => deadButSignedIn(umutClient)))!,
    );
    final relay = _Relay(SupabaseChatRepository(umutClient))
      ..sendVia = dead.send;
    final c = await mount(t, relay);
    final body = 'queued offline ${DateTime.now().microsecondsSinceEpoch}';

    await t.enterText(field, body);
    await t.pump();
    await t.tap(send);
    await t.pump();
    await until(t, () => relay.answers.length >= 2, 'a failure and a retry');

    for (final a in relay.answers) {
      final f = (a as Err<Message>).failure;
      expect(
        f is NetworkFailure && f.retryable,
        isTrue,
        reason: 'a dead host is "no connection": $f',
      );
    }
    expect(clock, findsOneWidget, reason: 'still on its way');
    expect(pendingIn(c), findsOneWidget);
    expect(find.byType(SisNotice), findsNothing, reason: 'no notice');
    expect(composerText(t), isEmpty, reason: 'the text does not come back');
    expect(await rowsWithBody(t, body), isEmpty);

    relay.sendVia = null; // the connection is back
    await until(
      t,
      () => relay.answers.any((a) => a is Ok<Message>),
      'the queued message to go by itself',
    );
    final stored = (relay.answers.last as Ok<Message>).value;
    await until(
      t,
      () => relay.echoed.contains(stored.id),
      'the real echo of ${stored.id}',
    );
    await t.pump();

    expect(relay.ids.toSet(), {stored.id}, reason: 'every attempt, one id');
    expect(relay.ids.length, greaterThanOrEqualTo(3));
    expectShownOnce(t, c, stored);
    expect(find.byType(SisNotice), findsNothing);
    final rows = await rowsWithBody(t, body);
    expect(rows, hasLength(1), reason: 'exactly one row');
    expect(rows.single['id'], stored.id);
    await unmount(t, c);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('the answer is lost after the row landed: the retry is read '
      'back as ours, one bubble, one row', (t) async {
    final relay = _Relay(SupabaseChatRepository(umutClient));
    var landed = 0;
    relay.sendVia =
        ({required id, required conversationId, required body, replyTo}) async {
          final r = await relay.real.send(
            id: id,
            conversationId: conversationId,
            body: body,
            replyTo: replyTo,
          );
          if (landed++ == 0) {
            expect(r, isA<Ok<Message>>(), reason: 'the first insert landed');
            // ...but the phone never hears back.
            return const Err(NetworkFailure('No connection', retryable: true));
          }
          return r;
        };
    final c = await mount(t, relay);
    final body = 'lost answer ${DateTime.now().microsecondsSinceEpoch}';

    await t.enterText(field, body);
    await t.pump();
    await t.tap(send);
    await t.pump();
    await until(
      t,
      () => relay.answers.any((a) => a is Ok<Message>),
      'the retry to be answered',
    );
    final stored = (relay.answers.last as Ok<Message>).value;
    await until(
      t,
      () => relay.echoed.contains(stored.id),
      'the real echo of ${stored.id}',
    );
    await t.pump();

    expect(relay.ids, hasLength(2));
    expect(relay.ids.toSet(), {stored.id}, reason: 'the retry reused the id');
    expect(stored.body, body);
    expectShownOnce(t, c, stored);
    expect(find.byType(SisNotice), findsNothing);
    expect(composerText(t), isEmpty);
    expect(await rowsWithBody(t, body), hasLength(1));
    await unmount(t, c);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
