@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
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
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/service_key.dart';
import '../support/reach.dart';

/// Message search's screens on their seams (v0.16), the whole app mounted as
/// main.dart mounts it for vedat: the real chat, presence and profile
/// repositories on the local stack, the real search RPC, messagesAround and
/// the real 500-message read. Only Google sign-in, the Play update API and
/// Firebase push -- nothing local to run them on -- are fakes. The failure
/// path of each connection the screens add (search, messagesAround) is the
/// same call on a real repository at a dead host.
///
/// Each run makes its own group of vedat and yesim holding 600 messages
/// (backdated through the service key), four of them carrying this run's
/// tag: two older than the newest 500, one loaded far up, one near the end.
///
/// Requires a running local Supabase, SUPABASE_TEST_SERVICE_KEY (see
/// test/support/service_key.dart), --concurrency=1. Accounts vedat/yesim
/// are the search suites' own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client([String key = _key]) => SupabaseClient(
  _url,
  key,
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
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

/// Letters only, unique per run: the search term.
final _tag = () {
  var n = DateTime.now().microsecondsSinceEpoch;
  final b = StringBuffer('q');
  while (n > 0) {
    b.writeCharCode(0x61 + n % 26);
    n ~/= 26;
  }
  return b.toString();
}();

/// Google sign-in cannot run locally: the session is the account's real one.
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

/// The real repository; search and messagesAround can be pointed at a real
/// repository on a dead host -- the phone going offline mid-way.
class _Switch implements ChatRepository {
  _Switch(this.live, this.dead);
  final ChatRepository live;
  final ChatRepository dead;
  bool searchOffline = false;
  bool aroundOffline = false;
  final arounds = <String>[];

  /// Every search asked, in order: (query, conversation).
  final searches = <(String, String?)>[];
  List<String> inChat(String room) => [
    for (final (q, c) in searches)
      if (c == room) q,
  ];

  /// While set, a search's real answer is held until it completes.
  Completer<void>? gate;

  @override
  Future<Result<List<Message>>> search(
    String query, {
    String? conversationId,
  }) async {
    searches.add((query, conversationId));
    final held = gate;
    final r = await (searchOffline ? dead : live).search(
      query,
      conversationId: conversationId,
    );
    if (held != null) await held.future;
    return r;
  }

  @override
  Future<Result<List<Message>>> messagesAround(String id, Message anchor) {
    arounds.add(anchor.id);
    return (aroundOffline ? dead : live).messagesAround(id, anchor);
  }

  @override
  Future<Result<List<ReadMark>>> readMarks(String id) => live.readMarks(id);
  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String id) =>
      live.readUpdates(id);
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
}

List<Override> _production(SupabaseClient client, ChatRepository chat) => [
  runtimeConfigProvider.overrideWithValue(
    const RuntimeConfig(
      supabaseUrl: _url,
      supabasePublishableKey: _key,
      googleWebClientId: 'c',
    ),
  ),
  authRepositoryProvider.overrideWithValue(_AccountAuth(client, 'Vedat')),
  updateRepositoryProvider.overrideWithValue(FakeUpdate()),
  chatRepositoryProvider.overrideWithValue(chat),
  presenceRepositoryProvider.overrideWithValue(
    SupabasePresenceRepository(client),
  ),
  profileRepositoryProvider.overrideWithValue(
    SupabaseProfileRepository(client),
  ),
  pushSourceProvider.overrideWithValue(PushSourceFake()),
  pushRegistryProvider.overrideWithValue(PushRegistryFake()),
];

/// Which of the 600 carry the tag (oldest first): 20 and 40 are older than
/// the newest 500 (100..599), 150 is loaded far up, 590 near the end.
const _hitAt = [20, 40, 150, 590];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient vedatClient;
  late SupabaseClient yesimClient;
  late SupabaseClient deadClient;
  late SupabaseChatRepository vedat;
  late SupabaseChatRepository yesim;
  late SupabaseChatRepository offline;
  late String room;

  /// The room's 600 message ids, oldest first.
  late List<String> ids;

  setUpAll(() async {
    vedatClient = await _signedIn('vedat@integration.test');
    yesimClient = await _signedIn('yesim@integration.test');
    deadClient = await deadButSignedIn(vedatClient);
    vedat = SupabaseChatRepository(vedatClient);
    yesim = SupabaseChatRepository(yesimClient);
    offline = SupabaseChatRepository(deadClient);
    final vedatId = vedatClient.auth.currentUser!.id;
    final yesimId = yesimClient.auth.currentUser!.id;
    await vedatClient
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', vedatId);
    await findByTag(vedatClient, [yesimClient]);
    room = (await vedat.startGroupConversation(
      title: 'jump',
      memberIds: [yesimId],
    ) as Ok<String>).value;

    final service = _client(serviceKey());
    final base = DateTime.now().toUtc().subtract(const Duration(hours: 2));
    final rows = [
      for (var i = 0; i < 600; i++)
        {
          'conversation_id': room,
          'sender_id': i.isEven ? vedatId : yesimId,
          'body': _hitAt.contains(i) ? 'hit $i $_tag' : 'filler $i',
          'created_at': base.add(Duration(seconds: i)).toIso8601String(),
        },
    ];
    final inserted = await service
        .from('messages')
        .insert(rows)
        .select('id, body');
    // Indexed by the number in the body: the answer's order is not promised.
    final byIndex = {
      for (final r in inserted)
        int.parse((r['body'] as String).split(' ')[1]): r['id'] as String,
    };
    ids = [for (var i = 0; i < 600; i++) byIndex[i]!];
    // Realtime reads inserts off the WAL in order and checks who subscribes
    // as it reads them, not as they were written. On a busy stack (CI) it
    // can still be reading the 600 above when a screen joins, and hands that
    // screen backdated rows as arrivals; a jumped-to hit is pushed up by
    // each, and off screen by enough ("never happened: the old hit on
    // screen", count still 4/4). So wait until it has read past them:
    // 'on top', written after them, arrives.
    final probe = await yesim.incoming(room);
    final arrived = (probe as Ok<Stream<Message>>).value
        .firstWhere((m) => m.body == 'on top')
        .timeout(const Duration(seconds: 30));
    // Now, so this run's room tops vedat's list above earlier runs' rooms.
    expect(
      await yesim.send(
        id: randomMessageId(),
        conversationId: room,
        body: 'on top',
      ),
      isA<Ok<Message>>(),
    );
    await arrived;
    await yesimClient.removeAllChannels();
    expect(ids, hasLength(600));
    await service.dispose();
  });

  tearDownAll(() async {
    for (final c in [vedatClient, yesimClient, deadClient]) {
      await c.dispose();
    }
  });

  Finder byKey(String k) => find.byKey(ValueKey(k));
  Finder bubble(int i) => byKey('message-${ids[i]}');
  Finder row(int i) => byKey('list-search-result-${ids[i]}');
  Finder editable(String k) => find.descendant(
    of: byKey(k),
    matching: find.byType(EditableText),
    matchRoot: true,
  );
  String count() => find
      .descendant(
        of: byKey('chat-search-count'),
        matching: find.byType(RichText),
        matchRoot: true,
      )
      .evaluate()
      .map((e) => (e.widget as RichText).text.toPlainText())
      .join(' ');
  Finder noticeSaying(String s) => find.descendant(
    of: find.byType(SisNotice),
    matching: find.textContaining(s),
  );

  /// Real time for the network, test time for debounces and animations.
  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 150; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
      if (ok()) return;
    }
    debugPrint(
      'DBG keys: ${find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate().map((e) => (e.widget.key! as ValueKey<String>).value).take(40).join(' ')}',
    );
    debugPrint(
      'DBG texts: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).take(40).join(' | ')}',
    );
    fail('never happened: $what');
  }

  /// A few more rounds so a scroll that follows a load has finished.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  bool inView(WidgetTester t, int i) {
    final b = bubble(i);
    if (b.evaluate().length != 1) return false;
    final list = find.ancestor(of: b, matching: find.byType(Scrollable)).first;
    final v = t.getRect(list), r = t.getRect(b);
    return r.top >= v.top - 1 && r.bottom <= v.bottom + 1;
  }

  /// Where hit [i] is, for a failure message.
  String where(WidgetTester t, int i) {
    final b = bubble(i);
    if (b.evaluate().isEmpty) {
      final shown = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('message-'),
          )
          .evaluate()
          .map((e) => (e.widget.key! as ValueKey<String>).value.substring(8))
          .map(ids.indexOf);
      return 'hit $i is not built; built: ${shown.toList()}';
    }
    final list = find.ancestor(of: b, matching: find.byType(Scrollable)).first;
    return 'hit $i at ${t.getRect(b)}, list at ${t.getRect(list)}';
  }

  Future<_Switch> mount(WidgetTester t) async {
    final chat = _Switch(vedat, offline);
    await t.pumpWidget(
      ProviderScope(
        overrides: _production(vedatClient, chat),
        child: const SisApp(),
      ),
    );
    await until(
      t,
      () => byKey('list-search-field').evaluate().isNotEmpty,
      'the chat list',
    );
    return chat;
  }

  Future<void> shutDown(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => vedatClient.removeAllChannels());
    await t.runAsync(() => vedatClient.realtime.disconnect());
    await t.pump(const Duration(seconds: 61));
  }

  Future<void> listSearch(WidgetTester t) async {
    await t.enterText(editable('list-search-field'), _tag);
    await until(
      t,
      () => _hitAt.every((i) => row(i).evaluate().isNotEmpty),
      'every tagged message as a result',
    );
  }

  Future<void> openRoomSearch(WidgetTester t) async {
    await t.enterText(editable('list-search-field'), '');
    await until(
      t,
      () => byKey('conversation-$room').evaluate().isNotEmpty,
      'the room in the list',
    );
    await t.tap(byKey('conversation-$room'));
    await until(
      t,
      () => bubble(599).evaluate().isNotEmpty,
      'the newest message',
    );
    await t.tap(byKey('chat-search-button'));
    await settle(t);
    await t.enterText(editable('chat-search-field'), _tag);
    // 590 and 150 are loaded; 40 and 20 are not, and only the server knows.
    await until(t, () => count() == '1/2+', 'the in-chat count');
  }

  testWidgets('list search -> tap a hit older than the newest 500 -> the chat '
      'opens on it: in-chat search on the same query, it current, in view', (
    t,
  ) async {
    try {
      final chat = await mount(t);
      await listSearch(t);
      final newestFirst = [
        for (final i in _hitAt.reversed) t.getRect(row(i)).top,
      ];
      expect(newestFirst, orderedEquals([...newestFirst]..sort()));

      await t.ensureVisible(row(20));
      await t.pump();
      await t.tap(row(20));
      await until(t, () => inView(t, 20), 'the old hit on screen');
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(
        t.widget<EditableText>(editable('chat-search-field')).controller.text,
        _tag,
      );
      expect(count(), '4/4');
      expect(chat.arounds, contains(ids[20]));
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  /// Taps [key] and waits for the count to read [want].
  Future<void> step(WidgetTester t, String key, String want) async {
    await t.tap(byKey(key));
    await until(t, () => count() == want, want);
    await settle(t);
  }

  testWidgets('in-chat: the newest hit, then ↑ to a loaded hit far up the '
      'list -- each in view', (t) async {
    try {
      final chat = await mount(t);
      await openRoomSearch(t);
      await settle(t);
      expect(inView(t, 590), isTrue, reason: where(t, 590));
      await step(t, 'chat-search-older', '2/2+');
      expect(inView(t, 150), isTrue, reason: where(t, 150));
      expect(chat.inChat(room), isEmpty, reason: 'answered from the phone');
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('in-chat ↑ into what is not loaded and ↓ back out of it: every '
      'hit in view', (t) async {
    try {
      final chat = await mount(t);
      await openRoomSearch(t);
      await step(t, 'chat-search-older', '2/2+');
      expect(chat.inChat(room), isEmpty, reason: 'loaded hits ask nothing');
      // Past the oldest loaded hit: the real server is asked, once, and its
      // four rows (two of them already shown) merge into four hits.
      await step(t, 'chat-search-older', '3/4');
      expect(chat.inChat(room), [_tag]);
      expect(inView(t, 40), isTrue, reason: 'unloaded: ${where(t, 40)}');
      expect(chat.arounds, contains(ids[40]), reason: 'loaded around it');
      await step(t, 'chat-search-older', '4/4');
      expect(inView(t, 20), isTrue, reason: where(t, 20));
      await step(t, 'chat-search-older', '4/4');
      expect(inView(t, 20), isTrue, reason: 'stops at the oldest');

      await step(t, 'chat-search-newer', '3/4');
      expect(inView(t, 40), isTrue, reason: where(t, 40));
      await step(t, 'chat-search-newer', '2/4');
      expect(inView(t, 150), isTrue, reason: 'back out: ${where(t, 150)}');
      await step(t, 'chat-search-newer', '1/4');
      expect(inView(t, 590), isTrue, reason: where(t, 590));
      expect(chat.inChat(room), [_tag], reason: 'answered once, for good');
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('close after jumping -> the normal header and the live newest '
      'messages, including one that arrived while searching', (t) async {
    try {
      await mount(t);
      await openRoomSearch(t);
      await step(t, 'chat-search-older', '2/2+');
      await step(t, 'chat-search-older', '3/4');
      await step(t, 'chat-search-older', '4/4');
      final sent = await t.runAsync(
        () => yesim.send(
          id: randomMessageId(),
          conversationId: room,
          body: 'while searching',
        ),
      );
      final late = (sent! as Ok<Message>).value;
      await settle(t);

      final container = ProviderScope.containerOf(
        t.element(find.byType(MessageScreen)),
      );
      await t.tap(byKey('chat-search-close'));
      await until(
        t,
        () =>
            container.read(messagesProvider).value?.last.id == late.id &&
            container.read(messagesProvider).value?.length == 500,
        'the live newest 500, ending with what arrived while searching',
      );
      await settle(t);
      expect(byKey('chat-search-field'), findsNothing);
      expect(byKey('conversation-title'), findsOneWidget);
      expect(bubble(20), findsNothing, reason: 'the jumped window is gone');
      expect(
        byKey('message-${late.id}'),
        findsOneWidget,
        reason: 'the newest message is not even built: ${where(t, 599)}',
      );
      final list = find
          .ancestor(
            of: byKey('message-${late.id}'),
            matching: find.byType(Scrollable),
          )
          .first;
      final v = t.getRect(list);
      final r = t.getRect(byKey('message-${late.id}'));
      expect(
        r.top >= v.top - 1 && r.bottom <= v.bottom + 1,
        isTrue,
        reason: 'the newest message is what shows after closing: $r in $v',
      );
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('offline: a failed list search keeps its results and shows the '
      'notice; a failed window load keeps the messages and shows the notice', (
    t,
  ) async {
    try {
      final chat = await mount(t);
      await listSearch(t);

      chat.searchOffline = true;
      await t.enterText(editable('list-search-field'), 'hit 5');
      await until(
        t,
        () => find.byType(SisNotice).evaluate().isNotEmpty,
        'the notice',
      );
      expect(noticeSaying(offlineMessage), findsOneWidget);
      expect(row(20), findsOneWidget, reason: 'the results stay');
      await settle(t);
      await t.pump(const Duration(seconds: 4));

      chat.searchOffline = false;
      chat.aroundOffline = true;
      await openRoomSearch(t);
      final container = ProviderScope.containerOf(
        t.element(find.byType(MessageScreen)),
      );
      List<String> shown() => container
          .read(messagesProvider)
          .requireValue
          .map((m) => m.id)
          .toList();
      final before = shown();
      await t.tap(byKey('chat-search-older')); // 150: loaded
      await until(t, () => count() == '2/2+', '2/2+');
      await settle(t);
      await t.tap(byKey('chat-search-older')); // 40: not loaded
      await until(
        t,
        () => find.byType(SisNotice).evaluate().isNotEmpty,
        'the notice',
      );
      expect(noticeSaying(offlineMessage), findsOneWidget);
      expect(shown(), before, reason: 'the previous messages stay');
      await t.pump(const Duration(seconds: 4));
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  /// Opens the room's search with nothing typed yet.
  Future<void> openRoom(WidgetTester t) async {
    await until(
      t,
      () => byKey('conversation-$room').evaluate().isNotEmpty,
      'the room in the list',
    );
    await t.tap(byKey('conversation-$room'));
    await until(
      t,
      () => bubble(599).evaluate().isNotEmpty,
      'the newest message',
    );
    await t.tap(byKey('chat-search-button'));
    await settle(t);
  }

  Future<void> typeInChat(WidgetTester t, String q) async {
    await t.enterText(editable('chat-search-field'), q);
    await t.pump();
  }

  testWidgets('in-chat, nothing loaded matches: the count stays empty (not '
      '"No results") until the real server answers for this room, then is '
      'exact; nothing anywhere: "No results" only after it answers', (t) async {
    try {
      final chat = await mount(t);
      await openRoom(t);
      chat.gate = Completer<void>();
      await typeInChat(t, 'hit 20 $_tag'); // only the unloaded 20
      await until(t, () => chat.inChat(room).isNotEmpty, 'the request');
      await settle(t);
      expect(chat.inChat(room), ['hit 20 $_tag']);
      expect(count(), isEmpty, reason: 'nothing known yet');
      chat.gate!.complete();
      chat.gate = null;
      await until(t, () => count() == '1/1', 'the server\'s exact count');
      await until(t, () => inView(t, 20), 'hit 20 on screen');

      chat.gate = Completer<void>();
      await typeInChat(t, 'nowhere $_tag');
      await until(t, () => chat.inChat(room).length == 2, 'the request');
      await settle(t);
      expect(count(), isEmpty);
      expect(find.text('No results'), findsNothing);
      chat.gate!.complete();
      chat.gate = null;
      await until(t, () => count() == 'No results', '"No results"');
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('in-chat: a late real answer to a query since replaced by a '
      'loaded one never shows', (t) async {
    try {
      final chat = await mount(t);
      await openRoom(t);
      chat.gate = Completer<void>();
      await typeInChat(t, 'hit 20 $_tag');
      await until(t, () => chat.inChat(room).isNotEmpty, 'the request');
      await typeInChat(t, _tag);
      await until(t, () => count() == '1/2+', 'the loaded hits');
      chat.gate!.complete();
      chat.gate = null;
      await settle(t);
      await settle(t);
      expect(count(), '1/2+', reason: 'hit 20\'s answer must not land');
      expect(chat.inChat(room), ['hit 20 $_tag'], reason: '_tag: loaded');
      expect(inView(t, 590), isTrue, reason: where(t, 590));
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('in-chat offline, nothing loaded matches: the SIS notice, the '
      'previous query\'s hits gone, never "No results"', (t) async {
    try {
      final chat = await mount(t);
      await openRoom(t);
      await typeInChat(t, _tag);
      await until(t, () => count() == '1/2+', 'the loaded hits');
      chat.searchOffline = true;
      await typeInChat(t, 'hit 20 $_tag');
      await until(
        t,
        () => find.byType(SisNotice).evaluate().isNotEmpty,
        'the notice',
      );
      expect(noticeSaying(offlineMessage), findsOneWidget);
      expect(count(), isEmpty, reason: 'not _tag\'s 1/2+, not "No results"');
      final container = ProviderScope.containerOf(
        t.element(find.byType(MessageScreen)),
      );
      expect(container.read(chatSearchProvider).hits, isEmpty);
      await t.pump(const Duration(seconds: 4));
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('in-chat offline, ↑ past the oldest loaded hit: the SIS notice, '
      'still on it, still "+"', (t) async {
    try {
      final chat = await mount(t);
      await openRoom(t);
      await typeInChat(t, _tag);
      await until(t, () => count() == '1/2+', 'the loaded hits');
      await step(t, 'chat-search-older', '2/2+');
      chat.searchOffline = true;
      await t.tap(byKey('chat-search-older'));
      await until(t, () => chat.inChat(room).isNotEmpty, 'the request');
      await settle(t);
      expect(count(), '2/2+');
      expect(inView(t, 150), isTrue, reason: where(t, 150));
      expect(
        noticeSaying(offlineMessage),
        findsOneWidget,
        reason: 'the ↑ press asked the server and it failed: say so',
      );
      await t.pump(const Duration(seconds: 4));
    } finally {
      await shutDown(t);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
