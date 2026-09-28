@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/reach.dart';

/// The search controllers on the real repository against the local stack,
/// wired as main.dart wires them: chatRepositoryProvider overridden with
/// [SupabaseChatRepository], nothing else.
///
/// The unit tests prove each controller against a fake; these prove the
/// seam -- the real RPC answering what the controllers expect (newest first,
/// scoped by the open conversation, a hit usable as messagesAround's anchor),
/// and each connection failing the way a phone offline fails.
///
/// Accounts vedat/yesim are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

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
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

/// Letters only, unique per run.
final _tag = () {
  var n = DateTime.now().microsecondsSinceEpoch;
  final b = StringBuffer('s');
  while (n > 0) {
    b.writeCharCode(0x61 + n % 26);
    n ~/= 26;
  }
  return b.toString();
}();

/// The real repository with its search calls counted, and -- per call, in
/// order -- optionally answered late: the real answer, held after the server
/// gave it, the way a slow network hands it over.
class _Counted implements ChatRepository {
  _Counted(this.live);

  /// Where the calls go; a test may point it at the dead host mid-way.
  ChatRepository live;
  final searches = <String>[];
  final lags = <Duration>[];

  // The open conversation's real 500-message read and its live feed: what
  // in-chat search answers from before it asks the server.
  @override
  Future<Result<List<Message>>> messages(String id) => live.messages(id);
  @override
  Future<Result<Stream<Message>>> incoming(String id) => live.incoming(id);
  @override
  Future<Result<List<Message>>> messagesAround(String id, Message anchor) =>
      live.messagesAround(id, anchor);
  @override
  Future<Result<void>> markRead(String id) => live.markRead(id);

  @override
  Future<Result<List<Message>>> search(
    String query, {
    String? conversationId,
  }) async {
    final n = searches.length;
    searches.add(query);
    final r = await live.search(query, conversationId: conversationId);
    if (n < lags.length) await Future<void>.delayed(lags[n]);
    return r;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not in this seam');
}

Future<void> _until(bool Function() done, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  SupabaseClient? vedatClient;
  SupabaseClient? yesimClient;
  SupabaseClient? deadClient;
  late SupabaseChatRepository vedat;
  late SupabaseChatRepository yesim;
  late SupabaseChatRepository offline;
  late String direct;
  late String room;
  late List<Message> hitsInDirect; // oldest first
  late Message inGroup;

  setUpAll(() async {
    vedatClient = await _signedIn('vedat@integration.test');
    yesimClient = await _signedIn('yesim@integration.test');
    vedat = SupabaseChatRepository(vedatClient!);
    yesim = SupabaseChatRepository(yesimClient!);
    deadClient = await deadButSignedIn(vedatClient!);
    offline = SupabaseChatRepository(deadClient!);
    final yesimId = yesimClient!.auth.currentUser!.id;
    await findByTag(vedatClient!, [yesimClient!]);
    direct = (await vedat.startDirectConversation(yesimId) as Ok<String>).value;
    room = (await vedat.startGroupConversation(
      title: 'search $_tag',
      memberIds: [yesimId],
    ) as Ok<String>).value;
    Future<Message> send(ChatRepository as, String c, String body) async =>
        (await as.send(
          id: randomMessageId(),
          conversationId: c,
          body: body,
        ) as Ok<Message>).value;
    hitsInDirect = [
      await send(vedat, direct, 'İstanbul $_tag one'),
      await send(yesim, direct, 'ISTANBUL $_tag two'),
      await send(vedat, direct, 'ıstanbul $_tag three'),
    ];
    await send(yesim, direct, 'unrelated $_tag');
    inGroup = await send(yesim, room, 'istanbul $_tag in the group');
  });

  tearDownAll(() async {
    for (final c in [vedatClient, yesimClient, deadClient]) {
      await c?.dispose();
    }
  });

  ProviderContainer wired(ChatRepository repository) {
    final c = ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(repository)],
    );
    c.listen(chatSearchProvider, (_, _) {});
    c.listen(chatListSearchProvider, (_, _) {});
    return c;
  }

  group('in-chat search', () {
    test('searches the open conversation only, newest hit current, and walks '
        'clamped both ways', () async {
      final c = wired(vedat);
      c.read(openConversationProvider.notifier).open(direct);
      final search = c.read(chatSearchProvider.notifier);

      expect(await search.search('istanbul $_tag'), isA<Ok<void>>());
      var s = c.read(chatSearchProvider);
      expect(
        s.hits.map((m) => m.id),
        hitsInDirect.reversed.map((m) => m.id),
        reason: 'the group\'s istanbul is not in this conversation',
      );
      expect(s.index, 0);
      expect(s.current!.id, hitsInDirect.last.id);

      search.next();
      search.next();
      search.next();
      s = c.read(chatSearchProvider);
      expect(s.index, 2, reason: 'clamped at the oldest');
      expect(s.current!.id, hitsInDirect.first.id);
      search.previous();
      search.previous();
      search.previous();
      expect(c.read(chatSearchProvider).index, 0, reason: 'clamped at newest');
    });

    test('a hit is a usable anchor: messagesAround centres on it', () async {
      final c = wired(vedat);
      c.read(openConversationProvider.notifier).open(direct);
      await c.read(chatSearchProvider.notifier).search('istanbul $_tag');
      c.read(chatSearchProvider.notifier).next();
      final hit = c.read(chatSearchProvider).current!;

      final window = await c
          .read(chatRepositoryProvider)
          .messagesAround(direct, hit);
      expect(window, isA<Ok<List<Message>>>());
      final ids = (window as Ok<List<Message>>).value.map((m) => m.id).toList();
      expect(ids, contains(hit.id));
      expect(
        ids.indexOf(hitsInDirect[0].id) < ids.indexOf(hit.id) &&
            ids.indexOf(hit.id) < ids.indexOf(hitsInDirect[2].id),
        isTrue,
        reason: 'oldest first, around the hit',
      );
    });

    test('opening another conversation resets it; the next search is scoped '
        'to that one', () async {
      final c = wired(vedat);
      c.read(openConversationProvider.notifier).open(direct);
      await c.read(chatSearchProvider.notifier).search('istanbul $_tag');
      expect(c.read(chatSearchProvider).hits, isNotEmpty);

      c.read(openConversationProvider.notifier).open(room);
      expect(c.read(chatSearchProvider).hits, isEmpty);
      expect(c.read(chatSearchProvider).index, -1);

      await c.read(chatSearchProvider.notifier).search('istanbul $_tag');
      expect(c.read(chatSearchProvider).hits.map((m) => m.id), [inGroup.id]);
    });

    test('loaded: the real messages answer at once, folded like the server '
        '(İ, I, ı), with no request; ↑ past the oldest asks once and the '
        'real answer merges without duplicates', () async {
      final counted = _Counted(vedat);
      final c = wired(counted);
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open(direct);
      await c.read(messagesProvider.future);
      final search = c.read(chatSearchProvider.notifier);

      expect(await search.search('istanbul $_tag'), isA<Ok<void>>());
      var s = c.read(chatSearchProvider);
      expect(s.hits.map((m) => m.id), hitsInDirect.reversed.map((m) => m.id));
      expect(s.serverAnswered, isFalse);
      expect(counted.searches, isEmpty, reason: 'answered from the phone');

      search.next();
      search.next();
      expect(c.read(chatSearchProvider).index, 2);
      expect(counted.searches, isEmpty, reason: 'walking local hits');
      search.next(); // past the oldest local hit
      await _until(
        () => c.read(chatSearchProvider).serverAnswered,
        'the server never answered the ↑',
      );
      expect(counted.searches, ['istanbul $_tag']);
      s = c.read(chatSearchProvider);
      expect(
        s.hits.map((m) => m.id),
        hitsInDirect.reversed.map((m) => m.id),
        reason: 'the server\'s rows are the same messages: each shown once',
      );
      expect(s.index, 2, reason: 'nothing older: stays on the oldest');
      search.next();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(counted.searches, hasLength(1), reason: 'never asked again');
    });

    test('switching chats: while the room\'s real messages load, the direct '
        'chat\'s loaded messages never answer for the room', () async {
      final counted = _Counted(vedat);
      final c = wired(counted);
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open(direct);
      await c.read(messagesProvider.future);

      c.read(openConversationProvider.notifier).open(room);
      final search = c.read(chatSearchProvider.notifier);
      final pending = search.search('istanbul $_tag');
      expect(
        c.read(chatSearchProvider).hits.where((m) => m.conversationId != room),
        isEmpty,
        reason: 'the direct chat\'s hits shown in the room',
      );
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.read(chatSearchProvider).hits.map((m) => m.id), [inGroup.id]);
    });

    test('offline: a loaded hit still answers; a search with none fails with '
        'the offline sentence and shows its own (empty) truth, never the '
        'previous query\'s hits', () async {
      final counted = _Counted(vedat);
      final c = wired(counted);
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open(direct);
      await c.read(messagesProvider.future);
      final search = c.read(chatSearchProvider.notifier);
      expect(await search.search('istanbul $_tag'), isA<Ok<void>>());
      expect(c.read(chatSearchProvider).hits, hasLength(3));

      counted.live = offline; // the connection drops
      expect(await search.search('unrelated $_tag'), isA<Ok<void>>());
      expect(c.read(chatSearchProvider).hits.single.body, 'unrelated $_tag');
      expect(counted.searches, isEmpty, reason: 'no network needed');

      final result = await search.search('nowhere $_tag');
      expect(result, isA<Err<void>>());
      final failure = (result as Err<void>).failure;
      expect(failure, isA<NetworkFailure>());
      expect((failure as NetworkFailure).message, offlineMessage);
      final after = c.read(chatSearchProvider);
      expect(after.query, 'nowhere $_tag');
      expect(after.hits, isEmpty);
      expect(after.index, -1);
      expect(after.serverAnswered, isFalse, reason: 'not "No results"');
    });

    test('no loaded hit: the real server answers for this chat only; a slow '
        'answer to a replaced query never lands', () async {
      final counted = _Counted(vedat)..lags.add(const Duration(seconds: 2));
      final c = wired(counted);
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open(direct);
      await c.read(messagesProvider.future);
      final search = c.read(chatSearchProvider.notifier);

      final slow = search.search('nowhere $_tag'); // asks, answers late
      await _until(() => counted.searches.length == 1, 'never asked');
      await search.search('istanbul $_tag'); // local
      await slow;
      final s = c.read(chatSearchProvider);
      expect(s.query, 'istanbul $_tag');
      expect(s.hits, hasLength(3), reason: 'the late "nothing" dropped');
      expect(s.serverAnswered, isFalse);

      await search.search('nowhere $_tag');
      expect(c.read(chatSearchProvider).serverAnswered, isTrue);
      expect(c.read(chatSearchProvider).hits, isEmpty);
      c.read(openConversationProvider.notifier).open(room);
      await c.read(messagesProvider.future);
      await search.search('$_tag in the group');
      expect(counted.searches, hasLength(2), reason: 'loaded in the room');
      expect(c.read(chatSearchProvider).hits.single.id, inGroup.id);
    });
  });

  group('chat-list search', () {
    test('debounced: one request for the last keystroke, results from every '
        'conversation, newest first', () async {
      final counted = _Counted(vedat);
      final c = wired(counted);
      final list = c.read(chatListSearchProvider.notifier);

      list.search('ist');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      list.search('istanbul $_tag');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(counted.searches, isEmpty, reason: 'inside the debounce');

      await _until(
        () => c.read(chatListSearchProvider).results.isNotEmpty,
        'results never arrived',
      );
      expect(counted.searches, ['istanbul $_tag']);
      expect(c.read(chatListSearchProvider).results.map((m) => m.id), [
        inGroup.id,
        ...hitsInDirect.reversed.map((m) => m.id),
      ]);

      list.search('');
      expect(c.read(chatListSearchProvider).results, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(counted.searches, hasLength(1), reason: 'empty asks nothing');
    });

    test('a slow real answer to an old query never overwrites the newer '
        'one', () async {
      final counted = _Counted(vedat)
        ..lags.addAll([const Duration(seconds: 2), Duration.zero]);
      final c = wired(counted);
      final list = c.read(chatListSearchProvider.notifier);

      list.search('istanbul $_tag');
      await _until(() => counted.searches.length == 1, 'first never asked');
      list.search('unrelated $_tag');
      await _until(
        () => c.read(chatListSearchProvider).results.isNotEmpty,
        'the newer answer never arrived',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final results = c.read(chatListSearchProvider).results;
      expect(results, hasLength(1));
      expect(results.single.body, 'unrelated $_tag');
    });

    test(
      'offline: the failure is dropped silently and the results stay',
      () async {
        final counted = _Counted(vedat);
        final c = wired(counted);
        final list = c.read(chatListSearchProvider.notifier);
        list.search('istanbul $_tag');
        await _until(
          () => c.read(chatListSearchProvider).results.isNotEmpty,
          'results never arrived',
        );
        final before = c
            .read(chatListSearchProvider)
            .results
            .map((m) => m.id)
            .toList();

        counted.live = offline; // the connection drops
        list.search('unrelated $_tag');
        await _until(() => counted.searches.length == 2, 'never asked');
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(
          c.read(chatListSearchProvider).results.map((m) => m.id),
          before,
          reason: 'the failed answer changed nothing',
        );
      },
    );
  });
}
