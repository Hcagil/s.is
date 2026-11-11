@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/last_session.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/push.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/drift_stores.dart';
import '../support/fakes.dart';
import '../support/last_session_fakes.dart';
import '../support/reach.dart';
import '../support/video_fakes.dart';

/// The app opening faster (v0.21.4, docs/DECISIONS.md 2026-09-28) against the
/// real local stack: the REAL [SupabaseChatRepository] and
/// [SupabaseProfileRepository] under SisApp wired as main.dart wires it, over
/// a pass-through HTTP client ([_Wire]) that can add a fixed delay to every
/// request -- the phone-to-server round trip the change is about -- and
/// records when each request started and finished.
///
/// Only this proves that `conversations()` really sends ONE request (rpc
/// chat_list), that it returns what the old eight reads returned, and that
/// with a slow connection opening the app costs the longer of the profile and
/// the list, not both added up.
///
/// Requires a running local Supabase and the warmup probe; run with
/// --concurrency=1. Accounts bram/dora/eli/finn are this suite's own
/// (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

class _Req {
  _Req(this.method, this.uri, this.start);
  final String method;
  final Uri uri;
  final Duration start;
  Duration? end;

  /// The table, view or function a PostgREST request reads.
  String get table => uri.pathSegments.last;
  bool get isRest => uri.path.startsWith('/rest/v1/');
  bool overlaps(_Req o) => start < o.end! && o.start < end!;

  /// The request with every uuid replaced, so two runs compare.
  String get shape =>
      '$method ${uri.path}?${uri.query}'.replaceAll(_uuid, '<id>');
  static final _uuid = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  );
  @override
  String toString() => '$table ${start.inMilliseconds}-${end?.inMilliseconds}';
}

/// Every request goes to the real server, [delay] later. With [oneAtATime]
/// each waits for the one before it to finish: the sequential reference.
/// With [lastAsked] each waits 40 ms less than the one asked before it, so
/// answers to requests sent together arrive in the reverse order.
class _Wire extends http.BaseClient {
  final _inner = http.Client();
  final _clock = Stopwatch()..start();
  Duration delay = Duration.zero;
  bool oneAtATime = false;
  bool lastAsked = false;

  /// A request to a table in [held] gets no answer until [release]: the
  /// server has not answered yet, however slow the phone is.
  final held = <String>{};
  var _held = Completer<void>();
  void release() {
    held.clear();
    if (!_held.isCompleted) _held.complete();
    _held = Completer<void>();
  }

  final log = <_Req>[];
  int _inFlight = 0;
  int maxInFlight = 0;
  Future<void> _last = Future<void>.value();

  /// Now, on the clock every [_Req] is stamped with.
  Duration get now => _clock.elapsed;

  List<_Req> get rest => [
    for (final r in log)
      if (r.isRest) r,
  ];

  void reset() {
    log.clear();
    lastAsked = false;
    maxInFlight = 0;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!oneAtATime) return _send(request);
    final before = _last;
    final mine = Completer<void>();
    _last = mine.future;
    await before;
    try {
      return await _send(request);
    } finally {
      mine.complete();
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    final r = _Req(request.method, request.url, _clock.elapsed);
    log.add(r);
    if (r.isRest && ++_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      final wait = lastAsked
          ? Duration(milliseconds: max(0, 240 - 40 * (log.length - 1)))
          : delay;
      await Future<void>.delayed(wait);
      if (held.contains(r.table)) await _held.future;
      final res = await _inner.send(request);
      final body = await res.stream.toBytes();
      r.end = _clock.elapsed;
      return http.StreamedResponse(
        Stream.value(body),
        res.statusCode,
        contentLength: body.length,
        request: res.request,
        headers: res.headers,
        isRedirect: res.isRedirect,
        persistentConnection: res.persistentConnection,
        reasonPhrase: res.reasonPhrase,
      );
    } finally {
      r.end ??= _clock.elapsed;
      if (r.isRest) _inFlight--;
    }
  }

  @override
  void close() => _inner.close();
}

/// A wire that is down: every request fails, and is recorded.
class _Down extends http.BaseClient {
  final sent = <Uri>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request.url);
    throw const SocketException('network down');
  }
}

Future<SupabaseClient> _signedIn(String email, [_Wire? wire]) async {
  final client = SupabaseClient(
    _url,
    _key,
    httpClient: wire,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
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

T _ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => throw TestFailure('Err: ${failure.message}'),
};

/// Everything a conversation shows, as one comparable line.
String _row(Conversation c) => [
  c.id,
  c.title,
  c.other?.userId,
  c.other?.displayName,
  c.other?.tag,
  c.other?.avatarPath,
  c.lastMessage,
  c.lastMessageAt?.toUtc().toIso8601String(),
  c.lastSenderId,
  c.unread,
  c.avatarPath,
].join('|');

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

void main() {
  // Real timers: the delay and the stopwatch are wall-clock time.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final wire = _Wire();
  final finnWire = _Wire();
  late SupabaseClient bram, dora, eli, finn;
  late String bramId, doraId, eliId;
  late SupabaseChatRepository chat;
  late String withDora, withEli, groupId, groupTitle, doraLast, bramLast;

  setUpAll(() async {
    bram = await _signedIn('bram@integration.test', wire);
    dora = await _signedIn('dora@integration.test');
    eli = await _signedIn('eli@integration.test');
    finn = await _signedIn('finn@integration.test', finnWire);
    bramId = bram.auth.currentUser!.id;
    doraId = dora.auth.currentUser!.id;
    eliId = eli.auth.currentUser!.id;
    await bram
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', bramId);

    chat = SupabaseChatRepository(bram);
    final doraChat = SupabaseChatRepository(dora);
    await findByTag(bram, [dora, eli]);
    withDora = _ok(await chat.startDirectConversation(doraId));
    withEli = _ok(await chat.startDirectConversation(eliId));
    groupTitle = _stamp('fast start');
    groupId = _ok(
      await chat.startGroupConversation(
        title: groupTitle,
        memberIds: [doraId, eliId],
      ),
    );
    // Earlier runs left unread messages; start this run from zero.
    _ok(await chat.markRead(withDora));
    _ok(await chat.markRead(withEli));

    _ok(
      await doraChat.send(
        id: randomMessageId(),
        conversationId: withDora,
        body: _stamp('from dora'),
      ),
    );
    doraLast = _stamp('from dora again');
    _ok(
      await doraChat.send(
        id: randomMessageId(),
        conversationId: withDora,
        body: doraLast,
      ),
    );
    bramLast = _stamp('from bram');
    _ok(
      await chat.send(
        id: randomMessageId(),
        conversationId: withEli,
        body: bramLast,
      ),
    );
  });

  tearDownAll(() async {
    for (final c in [bram, dora, eli, finn]) {
      await c.dispose();
    }
  });

  setUp(() {
    wire
      ..delay = Duration.zero
      ..oneAtATime = false
      ..reset();
  });

  group('conversations()', () {
    test('reads what the server holds: previews, senders, unread counts, '
        'the other member, the group', () async {
      final list = _ok(await chat.conversations());
      final ids = [for (final c in list) c.id];
      final mine = await bram
          .from('conversation_members')
          .select('conversation_id')
          .eq('user_id', bramId);
      expect(ids.toSet(), {
        for (final r in mine) r['conversation_id'] as String,
      }, reason: 'not exactly the conversations bram is in');
      expect(ids, hasLength(ids.toSet().length), reason: 'a chat twice');

      Conversation byId(String id) => list.firstWhere((c) => c.id == id);
      final d = byId(withDora);
      expect(d.other?.userId, doraId);
      expect(d.title, isNull);
      expect(d.lastMessage, doraLast);
      expect(d.lastSenderId, doraId);
      expect(d.unread, 2);

      final e = byId(withEli);
      expect(e.other?.userId, eliId);
      expect(e.lastMessage, bramLast);
      expect(e.lastSenderId, bramId);
      expect(e.unread, 0, reason: 'his own message counted');

      final g = byId(groupId);
      expect(g.title, groupTitle);
      expect(g.lastMessage, isNull);
      expect(g.unread, 0);

      expect(
        ids.indexOf(withEli),
        lessThan(ids.indexOf(withDora)),
        reason: 'not most recent first',
      );
    });

    test('sends exactly one request, rpc chat_list, and returns the same '
        'list whether sent alone or with others in flight', () async {
      wire.oneAtATime = true;
      final alone = _ok(await chat.conversations());
      expect(
        [for (final r in wire.rest) r.shape],
        ['GET /rest/v1/rpc/chat_list?'],
      );

      wire
        ..oneAtATime = false
        ..reset();
      final again = _ok(await chat.conversations());
      expect(
        [for (final r in wire.rest) r.shape],
        ['GET /rest/v1/rpc/chat_list?'],
      );
      expect(
        [for (final c in again) _row(c)],
        [for (final c in alone) _row(c)],
      );
    });

    test('costs one round trip, not two', () async {
      const delay = Duration(milliseconds: 300);
      wire.delay = delay;
      final list = _ok(await chat.conversations());
      expect(list, isNotEmpty);
      expect(
        [for (final r in wire.rest) r.shape],
        ['GET /rest/v1/rpc/chat_list?'],
        reason: 'one round trip means one request: ${wire.rest}',
      );
      expect(wire.maxInFlight, 1, reason: 'nothing sent beside the list');
    });

    test('chat_list holds what the eight old reads held', () async {
      final raw = Map<String, dynamic>.from(await bram.rpc('chat_list') as Map);
      expect(raw.keys.toSet(), {
        'members',
        'conversations',
        'archives',
        'pins',
        'hides',
        'profiles',
        'previews',
        'unread',
      });
      List<String> ids(Object? rows, String col) =>
          [for (final r in rows as List) (r as Map)[col] as String]..sort();
      final members = await bram
          .from('conversation_members')
          .select('conversation_id,user_id');
      expect(
        [
          for (final r in raw['members'] as List)
            '${(r as Map)['conversation_id']}|${r['user_id']}',
        ]..sort(),
        [for (final r in members) '${r['conversation_id']}|${r['user_id']}']
          ..sort(),
      );
      expect(
        ids(raw['conversations'], 'id'),
        ids(await bram.from('conversations').select('id'), 'id'),
      );
      expect(
        ids(raw['previews'], 'conversation_id'),
        ids(
          await bram.from('conversation_previews').select('conversation_id'),
          'conversation_id',
        ),
      );
      final unread = await bram.rpc('unread_counts') as List;
      expect(
        [
          for (final r in raw['unread'] as List)
            '${(r as Map)['conversation_id']}|${r['unread']}',
        ]..sort(),
        [
          for (final r in unread)
            '${(r as Map)['conversation_id']}|${r['unread']}',
        ]..sort(),
      );
      final profiles = ids(raw['profiles'], 'user_id');
      expect(profiles, isNot(contains(bramId)), reason: 'own profile');
      expect(profiles, containsAll([doraId, eliId]));
    });

    test(
      'with no conversations it is still one request and an empty list',
      () async {
        finnWire.reset();
        final list = _ok(await SupabaseChatRepository(finn).conversations());
        expect(list, isEmpty);
        expect([for (final r in finnWire.rest) r.table], ['chat_list']);
      },
    );

    test('without a signed-in user it is denied before any request', () async {
      final w = _Wire();
      final anon = SupabaseClient(_url, _key, httpClient: w);
      addTearDown(anon.dispose);
      final r = await SupabaseChatRepository(anon).conversations();
      expect(r, isA<Err<List<Conversation>>>());
      expect((r as Err<List<Conversation>>).failure, isA<DeniedFailure>());
      expect(w.log, isEmpty, reason: 'a request went out: ${w.log}');
    });

    test('a network error comes back as Err after one retry', () async {
      final w = _Down();
      final c = SupabaseClient(_url, _key, httpClient: w);
      addTearDown(c.dispose);
      // Sign-in cannot run on a dead wire; give the client a session by hand.
      final live = bram.auth.currentSession!;
      await c.auth
          .recoverSession(jsonEncode(live.toJson()))
          .catchError((_) => AuthResponse());
      w.sent.clear();
      expect(c.auth.currentUser, isNotNull, reason: 'no session to test with');
      final r = await SupabaseChatRepository(c).conversations();
      expect(r, isA<Err<List<Conversation>>>());
      final rpcs = w.sent.where((u) => u.path.endsWith('/rpc/chat_list'));
      expect(rpcs, hasLength(2), reason: 'one try plus one retry: ${w.sent}');
    });
  });

  testWidgets('opening the app over a slow connection costs the longer of '
      'the profile and the list, not both', (t) async {
    const delay = Duration(milliseconds: 500);
    wire
      ..delay = delay
      ..reset();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          ...videoOverrides(),
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: _url,
              supabasePublishableKey: _key,
              googleWebClientId: 'c',
            ),
          ),
          // Google sign-in and the Play API have nothing to run against
          // locally (docs/ARCHITECTURE.md); everything else bram's app
          // reads at start is real.
          authRepositoryProvider.overrideWithValue(
            FakeAuth(
              session: true,
              member: Member(userId: bramId, displayName: 'Bram'),
            ),
          ),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(bram),
          ),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(bram),
          ),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(bram),
          ),
          attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
          linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
          pushSourceProvider.overrideWithValue(
            PushSourceFake(status: PushPermissionStatus.authorized),
          ),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          notificationExplainerStoreProvider.overrideWithValue(
            NotificationExplainerStoreFake(shown: true),
          ),
        ],
        child: const SisApp(),
      ),
    );
    final tile = find.byKey(ValueKey('conversation-$withEli'));
    final deadline = wire.now + delay * 20;
    while (tile.evaluate().isEmpty && wire.now < deadline) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(tile, findsOneWidget, reason: 'the list never showed');
    expect(find.byType(HomeScreen), findsOneWidget);

    final readyAt = wire.now;
    final reqs = wire.rest;
    final members = reqs.firstWhere((r) => r.table == 'chat_list');
    // A profiles read that overlaps the list's request can only be the
    // member's own profile.
    expect(
      reqs.any((r) => r.table == 'own_profile' && r.overlaps(members)),
      isTrue,
      reason: 'the profile and the list were read one after the other: $reqs',
    );
    // Profile: one round trip. List: one. One after the other: two.
    // Counted as round trips, not wall-clock time: on a loaded CI runner the
    // server's own time stretches every request (a 500 ms delay measured
    // 787 ms), so a bound in seconds fails with the requests still perfectly
    // overlapped. A request's stage is 1 + the deepest stage that had
    // finished before it started; nothing the app waited on before the list
    // showed may sit deeper than the list's one round trip.
    final stage = <_Req, int>{};
    for (final r in [...reqs]..sort((a, b) => a.start.compareTo(b.start))) {
      stage[r] =
          1 +
          [
            for (final p in stage.keys)
              if (p.end != null && p.end! <= r.start) stage[p]!,
          ].fold(0, max);
    }
    expect(
      reqs.where((r) => r.table == 'chat_list'),
      hasLength(1),
      reason: 'the list is one request: $reqs',
    );
    expect(
      stage[reqs.firstWhere((r) => r.table == 'chat_list')],
      1,
      reason: 'the list waited for another request: $reqs',
    );
    final waited = [
      for (final r in reqs)
        if (r.end != null && r.end! <= readyAt) stage[r]!,
    ];
    expect(
      waited.fold(0, max),
      1,
      reason:
          'ready after ${readyAt - reqs.first.start}, behind more round '
          'trips than the list needs: $reqs',
    );

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  });

  group('the stored chat list (v0.24.0), over the real repository and the '
      'real encrypted store', () {
    late Directory dir;
    late String key;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('chat-list-seam-');
      FlutterSecureStorage.setMockInitialValues({});
      key = await const StoreKey().loadOrCreate();
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// bram's app as main.dart wires it, the stored list included (on a temp
    /// directory: path_provider has no platform side in a test).
    /// [marker] is the last-session file on the phone: shared by two starts,
    /// the second finds what the first left, as on a real phone.
    ProviderContainer app({
      Future<File> Function()? file,
      LastSessionStore? marker,
    }) => ProviderContainer(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'c',
          ),
        ),
        authRepositoryProvider.overrideWithValue(
          FakeAuth(
            session: true,
            member: Member(userId: bramId, displayName: 'Bram'),
          ),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(SupabaseChatRepository(bram)),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(bram),
        ),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(bram),
        ),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
        pushSourceProvider.overrideWithValue(
          PushSourceFake(status: PushPermissionStatus.authorized),
        ),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        notificationExplainerStoreProvider.overrideWithValue(
          NotificationExplainerStoreFake(shown: true),
        ),
        ...driftStoreOverrides(dir, key, file: file),
        lastSessionStoreProvider.overrideWithValue(
          marker ?? MemoryLastSessionStore(),
        ),
      ],
    );

    Future<void> pumpUntil(
      WidgetTester t,
      bool Function() ok,
      String what, {
      Duration within = const Duration(seconds: 20),
    }) async {
      final deadline = wire.now + within;
      while (!ok() && wire.now < deadline) {
        await t.pump(const Duration(milliseconds: 10));
      }
      expect(ok(), isTrue, reason: 'timed out waiting for $what');
    }

    testWidgets('saved after the server answers, shown from the phone on the '
        'next start before the server answers, erased on sign-out', (t) async {
      final file = storeFileIn(dir);
      final tile = find.byKey(ValueKey('conversation-$withEli'));

      /// What the stored list in [store] holds for bram, as text; null when
      /// nothing is saved.
      Future<String?> saved(DriftMessageStore store) async {
        final list = await t.runAsync(
          () => DriftChatListSnapshotStore(store).load(bramId),
        );
        if (list == null) return null;
        String text(Conversation x) => [
          x.id,
          x.title,
          x.lastMessage,
          x.other?.userId,
          x.other?.displayName,
          x.other?.tag,
        ].join('|');
        return list.map(text).join('\n');
      }

      // First start: nothing on the phone; the server's list is saved.
      final marker = MemoryLastSessionStore();
      var c = app(marker: marker);
      await t.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SisApp()),
      );
      await pumpUntil(t, () => tile.evaluate().isNotEmpty, 'the list');
      // Wait through the app's own store: a second store opening the file
      // while the app's is still opening can erase it (its failed first try
      // deletes the files), which lost the save in CI run 39137594193.
      final appStore = c.read(messageStoreProvider) as DriftMessageStore;
      final deadline = wire.now + const Duration(seconds: 20);
      String? seen;
      while (!(seen ?? '').contains(bramLast) && wire.now < deadline) {
        await t.pump(const Duration(milliseconds: 50));
        seen = await saved(appStore);
      }
      expect(seen, contains(bramLast), reason: 'the app never saved the list');
      expect(
        (marker.stored?.userId, marker.stored?.onboarded),
        (bramId, true),
        reason: 'the first start left no onboarded marker for bram',
      );
      await t.pumpWidget(const SizedBox());
      await t.runAsync(appStore.close);
      c.dispose();

      // On the phone: read back through a fresh store over the same file,
      // opened only after the app closed its own.
      expect(file.existsSync(), isTrue, reason: 'no store file');
      final fresh = driftStore(bramId, dir, key);
      final last = await saved(fresh);
      await t.runAsync(fresh.close);
      expect(
        last,
        contains(bramLast),
        reason: 'the snapshot of what the server returned, for its owner',
      );
      expect(last, contains(groupTitle));
      expect(last, contains(doraLast));
      expect(last, isNot(contains('@integration.test')), reason: 'an email');

      // Next start, over a slow connection: the stored list is on screen
      // before the server has answered the list's or the profile's request.
      // Both answers are held until the test releases them, not merely
      // delayed: a delay raced the store read (CI run 42488751395).
      wire
        ..delay = const Duration(milliseconds: 1500)
        ..reset()
        ..held.addAll(['chat_list', 'own_profile']);
      addTearDown(wire.release);
      c = app(marker: marker);
      await t.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SisApp()),
      );
      await pumpUntil(t, () => tile.evaluate().isNotEmpty, 'the stored list');
      expect(
        [
          for (final r in wire.rest)
            if ({'chat_list', 'own_profile'}.contains(r.table) && r.end != null)
              r,
        ],
        isEmpty,
        reason: 'the list waited for the server: ${wire.rest}',
      );
      expect([
        for (final x in c.read(conversationListProvider).value!) x.id,
      ], containsAll([withDora, withEli, groupId]));

      // The server's answer then replaces it quietly: still on screen.
      wire.release();
      await pumpUntil(
        t,
        () => wire.rest.any((r) => r.table == 'chat_list' && r.end != null),
        "the server's list",
      );
      await t.pump(const Duration(milliseconds: 200));
      expect(tile, findsOneWidget);

      // Signing out through the app erases it.
      wire.delay = Duration.zero;
      await t.runAsync(
        () => c.read(sessionControllerProvider.notifier).signOut(),
      );
      await pumpUntil(t, () => !file.existsSync(), 'the erase');
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(file.existsSync(), isFalse, reason: 're-created after the erase');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => quit(c));
    });

    testWidgets('a store that cannot be read or written never stops the '
        "server's list", (t) async {
      final c = app(
        file: () async => throw const FileSystemException('no storage'),
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SisApp()),
      );
      await pumpUntil(
        t,
        () =>
            find.byKey(ValueKey('conversation-$withEli')).evaluate().isNotEmpty,
        'the list',
      );
      // Long enough for the save after the load to have failed too: an
      // error escaping it must land in this test, not after it.
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.read(conversationListProvider).hasError, isFalse);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 50));
    });
  });
}
