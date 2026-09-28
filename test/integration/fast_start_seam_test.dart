@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
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

import '../support/fakes.dart';

/// The app opening faster (v0.21.4, docs/DECISIONS.md 2026-09-28) against the
/// real local stack: the REAL [SupabaseChatRepository] and
/// [SupabaseProfileRepository] under SisApp wired as main.dart wires it, over
/// a pass-through HTTP client ([_Wire]) that can add a fixed delay to every
/// request -- the phone-to-server round trip the change is about -- and
/// records when each request started and finished.
///
/// The unit tests prove the order of calls against fakes. Only this proves
/// that `conversations()` really sends its five reads as two groups, that
/// running them together returns what running them one by one returns, and
/// that with a slow connection opening the app costs the longer of the
/// profile and the list, not both added up.
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

    test('together returns exactly what one by one returns, from the same '
        'requests, even when the answers come back in reverse order', () async {
      wire.oneAtATime = true;
      final oneByOne = _ok(await chat.conversations());
      final sequential = [for (final r in wire.rest) r.shape]..sort();
      expect(wire.maxInFlight, 1, reason: 'the reference was not sequential');

      wire
        ..oneAtATime = false
        ..reset()
        ..lastAsked = true;
      final together = _ok(await chat.conversations());
      final concurrent = [for (final r in wire.rest) r.shape]..sort();

      expect(
        [for (final c in together) _row(c)],
        [for (final c in oneByOne) _row(c)],
      );
      expect(concurrent, sequential);
      final asked = [for (final r in wire.rest) r.table];
      final answered = [
        for (final r in [
          ...wire.rest,
        ]..sort((a, b) => a.end!.compareTo(b.end!)))
          r.table,
      ];
      expect(answered, isNot(asked), reason: 'the answers were not reordered');
    });

    test('sends its five reads as two groups: members and conversations, '
        'then names, previews and unread counts', () async {
      const delay = Duration(milliseconds: 300);
      wire.delay = delay;
      final clock = Stopwatch()..start();
      final list = _ok(await chat.conversations());
      final took = clock.elapsed;
      expect(list, isNotEmpty);

      final reqs = wire.rest;
      expect([for (final r in reqs) r.table]..sort(), [
        'conversation_members',
        'conversation_previews',
        'conversations',
        'profiles',
        'unread_counts',
      ], reason: 'not the same five reads');
      _Req one(String t) => reqs.singleWhere((r) => r.table == t);
      final first = [one('conversation_members'), one('conversations')];
      final second = [
        one('profiles'),
        one('conversation_previews'),
        one('unread_counts'),
      ];
      expect(
        first[0].overlaps(first[1]),
        isTrue,
        reason: 'members and conversations one after the other: $reqs',
      );
      for (final a in second) {
        for (final b in second) {
          if (a != b) {
            expect(a.overlaps(b), isTrue, reason: 'not together: $reqs');
          }
        }
        for (final f in first) {
          expect(
            a.start >= f.end!,
            isTrue,
            reason: '${a.table} did not wait for ${f.table}: $reqs',
          );
        }
      }
      expect(wire.maxInFlight, 3);
      expect(took, greaterThanOrEqualTo(delay * 2));
      expect(
        took,
        lessThan(delay * 3),
        reason: 'two round trips expected, took $took: $reqs',
      );
    });

    test('with no conversations it stops after the first group', () async {
      finnWire.reset();
      final list = _ok(await SupabaseChatRepository(finn).conversations());
      expect(list, isEmpty);
      expect([for (final r in finnWire.rest) r.table]..sort(), [
        'conversation_members',
        'conversations',
      ]);
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

    // From the first request the app made, once it knew who is signed in.
    final reqs = wire.rest;
    final ready = wire.now - reqs.first.start;
    final members = reqs.firstWhere((r) => r.table == 'conversation_members');
    // A profiles read that overlaps the list's first group can only be the
    // member's own profile: the other members' names wait for that group.
    expect(
      reqs.any((r) => r.table == 'profiles' && r.overlaps(members)),
      isTrue,
      reason: 'the profile and the list were read one after the other: $reqs',
    );
    // Profile: one round trip. List: two. One after the other: three.
    expect(
      ready,
      lessThan(delay * 2.5),
      reason: 'ready after $ready, about the sum of the round trips: $reqs',
    );

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  });
}
