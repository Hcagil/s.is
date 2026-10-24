// Seam: StoreSyncController.run <-> REAL encrypted DriftMessageStore (temp
// files, one per account as main.dart wires it) <-> a server fake whose change
// feed, newest page and older pages follow the ChatRepository contract.
// Written from the Private Chats step 1 Group C contract, never the code:
// - fresh store: newestChange is saved as the cursor before any fill read;
//   each chat gets its newest page, then older pages until complete, newest
//   chat first; a killed fill resumes from contiguousFrom, finished chats are
//   not fetched again; media is never requested;
// - stored cursor: the first feed read starts 5 s before it with the nil id;
//   pages until a short one; the cursor is saved after each page and never
//   moves back; chats not in the list are not stored; vanished rows are
//   removed; an Err leaves the cursor;
// - a run() during a pass restarts it, catch-up first; an offline list, no
//   store or no Allowed session do nothing; an account change or a sign-out
//   (erase) during a pass stops it with nothing written;
// - an open chat still loading its first page delays the fill (max ~3 s).
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/catch_up_mark.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';

import '../../support/drift_stores.dart';
import '../../support/fakes.dart';
import '../../support/opener_fakes.dart' show ForgetSpyOpener;
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _nil = '00000000-0000-0000-0000-000000000000';

int _cmp(ChangeCursor a, ChangeCursor b) {
  final t = a.updatedAt.compareTo(b.updatedAt);
  return t != 0 ? t : a.id.compareTo(b.id);
}

/// The server: [history] per chat (oldest first) plus an account-wide change
/// log ordered by (updatedAt, id), one entry per row (its latest change).
/// Never instant; any read can be held or made to fail by call number.
class _Feed extends ChatFake {
  _Feed() : super(latency: const Duration(milliseconds: 1));

  final _log = <(Message, ChangeCursor)>[];
  final feedCalls = <ChangeCursor>[];
  final beforeCalls = <({String chat, DateTime before, int limit})>[];

  /// changesSince / messagesBefore call number (1-based) -> held until done.
  final changeGates = <int, Completer<void>>{};
  final beforeGates = <int, Completer<void>>{};

  /// When set, newestChange waits for it.
  Completer<void>? newestGate;

  /// changesSince call numbers that answer Err.
  final changeErrs = <int>{};

  /// The first-page read of this chat waits for [chatGate].
  String? holdChat;
  final chatGate = Completer<void>();

  void change(Message m, {DateTime? at}) {
    _log.removeWhere((e) => e.$1.id == m.id);
    _log.add((m, ChangeCursor(at ?? m.createdAt, m.id)));
    _log.sort((a, b) => _cmp(a.$2, b.$2));
  }

  ChangeCursor? get newest => _log.isEmpty ? null : _log.last.$2;

  Future<void> _wait() => Future<void>.delayed(latency);

  @override
  Future<Result<ChangePage>> changesSince(
    ChangeCursor cursor, {
    int limit = 500,
  }) async {
    calls.add('changesSince');
    feedCalls.add(cursor);
    final n = feedCalls.length;
    await _wait();
    if (changeGates[n] case final g?) await g.future;
    if (changeErrs.contains(n)) return const Err(NetworkFailure('offline'));
    final rows = _log.where((e) => _cmp(e.$2, cursor) > 0).take(limit).toList();
    return Ok(
      ChangePage([
        for (final e in rows) e.$1,
      ], rows.isEmpty ? null : rows.last.$2),
    );
  }

  @override
  Future<Result<ChangeCursor?>> newestChange() async {
    calls.add('newestChange');
    await _wait();
    if (newestGate case final g?) await g.future;
    return Ok(newest);
  }

  @override
  Future<Result<List<Message>>> messagesBefore(
    String conversationId,
    DateTime before, {
    int limit = 500,
  }) async {
    calls.add('before:$conversationId');
    beforeCalls.add((chat: conversationId, before: before, limit: limit));
    final n = beforeCalls.length;
    await _wait();
    if (beforeGates[n] case final g?) await g.future;
    final rows = [
      for (final m in history[conversationId] ?? const <Message>[])
        if (!m.createdAt.isAfter(before)) m,
    ];
    return Ok(rows.length > limit ? rows.sublist(rows.length - limit) : rows);
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    if (conversationId == holdChat) {
      calls.add('held:$conversationId');
      await chatGate.future;
    }
    return super.messages(conversationId);
  }

  int count(String prefix) => calls.where((c) => c.startsWith(prefix)).length;
}

/// Records cursor saves into the server's call log too, so their order
/// against the reads is visible.
class _Spy extends SpyStore {
  _Spy(super.inner, this.feed);
  final _Feed feed;
  final saved = <ChangeCursor>[];

  /// When set, upsertAll is recorded at once and then waits for it.
  Completer<void>? holdUpsert;

  static const _writeOps = [
    'upsert:',
    'reconcile:',
    'extendOlder:',
    'remove:',
    'deleteConversation:',
    'clear',
  ];

  /// Every write asked of this store so far, cursor saves included.
  int get writes =>
      calls.where((c) => _writeOps.any(c.startsWith)).length + saved.length;

  /// While above zero, each upsertAll fails as the real store does once its
  /// retries are spent (StoreWriteException), writing nothing.
  int failUpserts = 0;

  @override
  Future<void> upsertAll(List<Message> messages) async {
    if (failUpserts > 0) {
      failUpserts--;
      calls.add('upsert-failed');
      throw const StoreWriteException();
    }
    final f = super.upsertAll(messages);
    if (holdUpsert case final g?) await g.future;
    return f;
  }

  @override
  Future<void> saveCursor(ChangeCursor cursor) {
    saved.add(cursor);
    feed.calls.add('saveCursor');
    return super.saveCursor(cursor);
  }
}

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
  void become(SessionState s) => state = AsyncData(s);
}

Allowed _allowed(String id) => Allowed(Member(userId: id, displayName: id));

List<Message> _rows(String conv, int from, int to) => [
  for (var i = from; i < to; i++) msg('$conv-$i', conv: conv, t: i),
];

Conversation _chat(String id, int t) =>
    Conversation(id: id, lastMessageAt: at(t));

void main() {
  late StoreHarness h;
  late String key;
  late _Feed feed;

  /// Every store the override built, by account.
  final opened = <String, List<_Spy>>{};

  Override storeOverride() => messageStoreProvider.overrideWith((ref) {
    final uid = ref.watch(currentUserIdProvider) ?? '';
    final dir = Directory('${h.dir.path}/u$uid')..createSync(recursive: true);
    final real = driftStore(uid, dir, key);
    final s = _Spy(real, feed);
    (opened[uid] ??= []).add(s);
    ref.onDispose(real.close);
    return s;
  });

  /// A store opened on [uid]'s file outside any container (to read it back).
  DriftMessageStore reopen(String uid) {
    final dir = Directory('${h.dir.path}/u$uid')..createSync(recursive: true);
    final s = driftStore(uid, dir, key);
    addTearDown(s.close);
    return s;
  }

  Future<ProviderContainer> boot({
    SessionState? session,
    bool withStore = true,
    List<Override> more = const [],
  }) async {
    final c = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(feed),
        sessionControllerProvider.overrideWith(
          () => _Session(session ?? _allowed('me')),
        ),
        ...videoOverrides(),
        if (withStore) storeOverride(),
        ...more,
      ],
    );
    addTearDown(withStore ? () => quit(c) : c.dispose);
    c.listen(currentUserIdProvider, (_, _) {});
    await c.read(sessionControllerProvider.future);
    return c;
  }

  _Spy storeOf(ProviderContainer c) => c.read(messageStoreProvider) as _Spy;

  Future<void> run(ProviderContainer c) =>
      c.read(storeSyncProvider).run().timeout(const Duration(seconds: 20));

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    feed = _Feed();
    opened.clear();
  });

  group('fresh store', () {
    test('saves newestChange as the cursor before any fill read', () async {
      feed.history['c1'] = _rows('c1', 0, 10);
      for (final m in feed.history['c1']!) {
        feed.change(m);
      }
      feed.conversationsResult = Ok([_chat('c1', 9)]);
      final c = await boot();
      final store = storeOf(c);
      await run(c);

      final saved = await store.cursor();
      expect(saved?.id, feed.newest!.id);
      expect(saved!.updatedAt.isAtSameMomentAs(feed.newest!.updatedAt), isTrue);
      final save = feed.calls.indexOf('saveCursor');
      final firstFill = feed.calls.indexWhere(
        (x) => x.startsWith('messages:') || x.startsWith('before:'),
      );
      expect(save, isNonNegative);
      expect(firstFill, isNonNegative);
      expect(save, lessThan(firstFill), reason: 'cursor saved BEFORE fill');
    });

    test('each chat: newest page, then older pages until complete, newest '
        'chat first; media never requested', () async {
      feed.history['c1'] = [
        ..._rows('c1', 0, 399),
        Message(
          id: 'c1-photo',
          conversationId: 'c1',
          senderId: 'u1',
          body: '',
          createdAt: at(399),
          attachmentPath: 'c1/p.jpg',
        ),
      ];
      feed.history['c2'] = _rows('c2', 1000, 1010);
      feed.change(feed.history['c2']!.last);
      feed.conversationsResult = Ok([_chat('c2', 1009), _chat('c1', 399)]);
      final c = await boot();
      final store = storeOf(c);
      await run(c);
      await eventually(
        () async => (await store.syncState('c1'))?.complete ?? false,
        timeout: const Duration(seconds: 10),
        reason: 'c1 filled to its first message',
      );

      expect(
        feed.calls.indexOf('messages:c2'),
        lessThan(feed.calls.indexOf('messages:c1')),
        reason: 'newest chat first',
      );
      expect(
        ids(await store.newest('c1', limit: 1000)).toSet(),
        feed.history['c1']!.map((m) => m.id).toSet(),
      );
      expect((await store.syncState('c2'))?.complete, isTrue);
      expect(feed.beforeCalls.where((b) => b.chat == 'c2'), isEmpty);
      expect(feed.beforeCalls, isNotEmpty);
      expect(feed.beforeCalls.every((b) => b.limit == 300), isTrue);
      expect(
        feed.calls.where(
          (x) =>
              x.startsWith('previews') ||
              x.startsWith('attachmentBytes') ||
              x.startsWith('attachmentUrl'),
        ),
        isEmpty,
        reason: 'media is never requested by the fill',
      );
    });

    test('a killed fill resumes from contiguousFrom; finished chats are not '
        'fetched again', () async {
      feed.history['c1'] = _rows('c1', 0, 700);
      feed.history['c2'] = _rows('c2', 1000, 1010);
      feed.change(feed.history['c2']!.last);
      feed.conversationsResult = Ok([_chat('c2', 1009), _chat('c1', 699)]);
      feed.beforeGates[2] = Completer<void>();
      final a = await boot();
      final storeA = storeOf(a);
      unawaited(a.read(storeSyncProvider).run());
      await eventually(
        () => feed.beforeCalls.length == 2 && storeA.count('extendOlder') == 1,
        reason: 'first older page stored, second in flight',
      );
      final from = (await storeA.syncState('c1'))!.contiguousFrom!;
      await quit(a); // the app is killed mid-fill
      final before = feed.calls.length;

      final b = await boot();
      await run(b);
      final storeB = storeOf(b);
      await eventually(
        () async => (await storeB.syncState('c1'))?.complete ?? false,
        timeout: const Duration(seconds: 10),
        reason: 'c1 completed after the restart',
      );
      final after = feed.calls.sublist(before);
      expect(after, isNot(contains('messages:c1')));
      expect(after, isNot(contains('messages:c2')));
      expect(after, isNot(contains('before:c2')));
      final resumed = feed.beforeCalls.skip(2).first;
      expect(resumed.chat, 'c1');
      expect(
        resumed.before.isAtSameMomentAs(from),
        isTrue,
        reason: 'resumes at the stored contiguousFrom',
      );
      expect(ids(await storeB.newest('c1', limit: 1000)).length, 700);
      feed.beforeGates[2]!.complete();
    });
  });

  group('stored cursor', () {
    final cursor = ChangeCursor(at(100), 'c1-100');

    /// A stored, complete c1 (no fill noise) and the saved cursor.
    Future<(ProviderContainer, _Spy)> withCursor({
      List<String> listed = const ['c1'],
      List<Override> more = const [],
    }) async {
      feed.conversationsResult = Ok([for (final id in listed) _chat(id, 100)]);
      final c = await boot(more: more);
      final store = storeOf(c);
      for (final id in listed) {
        await store.reconcilePage(id, [
          msg('$id-seed', conv: id, t: 1),
        ], reachedStart: true);
      }
      await store.saveCursor(cursor);
      store.saved.clear();
      feed.calls.clear();
      return (c, store);
    }

    // R1: the catch-up mark. A pass counts only when the feed was read to its
    // end; a failed or partial read does not mark it; a stamp taken after a
    // pass began is not covered by that pass.
    group('R1 catch-up mark', () {
      Future<(CatchUpMark, List<int>)> markOf(ProviderContainer c) async {
        final mark = c.read(catchUpMarkProvider);
        final fired = <int>[];
        final sub = mark.passes.listen((_) => fired.add(1));
        addTearDown(sub.cancel);
        return (mark, fired);
      }

      test('a feed read to its end covers a stamp taken before the pass, '
          'and fires passes', () async {
        feed.change(msg('c1-new', t: 200));
        final (c, _) = await withCursor();
        final (mark, fired) = await markOf(c);
        final s = mark.stamp();
        expect(mark.covers(s), isFalse, reason: 'no pass yet');
        await run(c);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(mark.covers(s), isTrue);
        expect(fired, isNotEmpty);
      });

      test('an Err on the first page does not mark the pass', () async {
        feed.change(msg('c1-new', t: 200));
        feed.changeErrs.addAll([1, 2, 3, 4, 5, 6]);
        final (c, _) = await withCursor();
        final (mark, fired) = await markOf(c);
        final s = mark.stamp();
        await run(c);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(mark.covers(s), isFalse);
        expect(fired, isEmpty);
      });

      test(
        'a partial read (page 1 kept, then Err) does not mark the pass',
        () async {
          final rows = [
            for (var i = 0; i < 600; i++)
              msg('c1-p${i.toString().padLeft(4, '0')}', t: 101 + i),
          ];
          rows.forEach(feed.change);
          feed.changeErrs.addAll([2, 3, 4, 5, 6]);
          final (c, store) = await withCursor();
          final (mark, fired) = await markOf(c);
          final s = mark.stamp();
          await run(c);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(
            (await store.cursor())?.id,
            rows[499].id,
            reason: 'fixture: the first page was applied',
          );
          expect(mark.covers(s), isFalse);
          expect(fired, isEmpty);
        },
      );

      test('a stamp taken while a pass is in flight is not covered by it; '
          'the next full pass covers it', () async {
        feed.change(msg('c1-new', t: 200));
        feed.changeGates[1] = Completer<void>();
        final (c, _) = await withCursor();
        final (mark, _) = await markOf(c);
        final first = c.read(storeSyncProvider).run();
        await eventually(
          () => feed.feedCalls.length == 1,
          reason: 'the pass is reading the feed',
        );
        final s = mark.stamp();
        feed.changeGates[1]!.complete();
        await first.timeout(const Duration(seconds: 20));
        expect(mark.covers(s), isFalse, reason: 'that pass began earlier');
        await run(c);
        expect(mark.covers(s), isTrue);
      });
    });

    test(
      'the first read starts 5 s before the cursor with the nil id',
      () async {
        final (c, _) = await withCursor();
        await run(c);
        final first = feed.feedCalls.first;
        expect(
          first.updatedAt.isAtSameMomentAs(
            cursor.updatedAt.subtract(const Duration(seconds: 5)),
          ),
          isTrue,
          reason: 'got ${first.updatedAt}',
        );
        expect(first.id, _nil);
      },
    );

    test('pages until a short one; the cursor is saved after each page and '
        'only moves forward', () async {
      final rows = [
        for (var i = 0; i < 1100; i++)
          msg('c1-n${i.toString().padLeft(4, '0')}', t: 101 + i),
      ];
      rows.forEach(feed.change);
      feed.changeGates[2] = Completer<void>();
      final (c, store) = await withCursor();
      unawaited(c.read(storeSyncProvider).run());
      await eventually(
        () => feed.feedCalls.length == 2,
        reason: 'second page asked for',
      );
      expect(store.saved.single.id, rows[499].id, reason: 'saved after page 1');
      expect((await store.cursor())?.id, rows[499].id);
      expect(feed.feedCalls[1].id, rows[499].id, reason: 'true last cursor');
      feed.changeGates[2]!.complete();
      await eventually(
        () async => (await store.cursor())?.id == rows.last.id,
        reason: 'cursor at the last change',
      );
      expect(feed.feedCalls.length, 3);
      expect(feed.feedCalls[2].id, rows[999].id);
      for (var i = 1; i < store.saved.length; i++) {
        expect(_cmp(store.saved[i], store.saved[i - 1]), greaterThan(0));
      }
      expect(
        ids(await store.newest('c1', limit: 2000)),
        containsAll(rows.map((m) => m.id)),
      );
    });

    test('an overlap page of rows older than the cursor never moves it '
        'back', () async {
      final old = [msg('c1-o1', t: 99), msg('c1-o2', t: 99)];
      for (final m in old) {
        feed.change(
          m,
          at: cursor.updatedAt.subtract(const Duration(seconds: 2)),
        );
      }
      final (c, store) = await withCursor();
      await run(c);
      final now = (await store.cursor())!;
      expect(now.id, cursor.id);
      expect(now.updatedAt.isAtSameMomentAs(cursor.updatedAt), isTrue);
      for (final s in store.saved) {
        expect(_cmp(s, cursor), greaterThanOrEqualTo(0));
      }
      expect(feed.feedCalls, isNotEmpty);
    });

    test('rows of chats not in the list are not stored', () async {
      feed.change(msg('c1-new', t: 200));
      feed.change(msg('cx-new', conv: 'cx', t: 201));
      final (c, store) = await withCursor();
      await run(c);
      expect(ids(await store.newest('c1')), contains('c1-new'));
      expect(await store.newest('cx'), isEmpty);
    });

    test('a vanished row is removed; a placeholder is stored as one', () async {
      final (c, store) = await withCursor();
      await store.upsertAll([msg('c1-v', t: 50), msg('c1-p', t: 51)]);
      feed.change(
        msg('c1-v', t: 50, deletion: MessageDeletion.vanished),
        at: at(200),
      );
      feed.change(
        msg('c1-p', t: 51, body: '', deletion: MessageDeletion.placeholder),
        at: at(201),
      );
      await run(c);
      final stored = await store.newest('c1');
      expect(ids(stored), isNot(contains('c1-v')));
      expect(
        stored.firstWhere((m) => m.id == 'c1-p').deletion,
        MessageDeletion.placeholder,
      );
    });

    // Group E: the opener forgets a vanished row BEFORE the store drops it.
    test('a vanished row is forgotten by the opener, then removed; a '
        'placeholder is not forgotten', () async {
      _Spy? spy;
      final (c, store) = await withCursor(
        more: [
          messageOpenerProvider.overrideWithValue(
            ForgetSpyOpener((id) => spy!.calls.add('forget:$id')),
          ),
        ],
      );
      spy = store;
      await store.upsertAll([msg('c1-v', t: 50), msg('c1-p', t: 51)]);
      store.calls.clear();
      feed.change(
        msg('c1-v', t: 50, deletion: MessageDeletion.vanished),
        at: at(200),
      );
      feed.change(
        msg('c1-p', t: 51, body: '', deletion: MessageDeletion.placeholder),
        at: at(201),
      );
      await run(c);
      expect(
        store.calls.where((x) => x.startsWith('forget:') || x == 'remove:c1-v'),
        ['forget:c1-v', 'remove:c1-v'],
      );
    });

    test('an Err on the first page leaves the cursor', () async {
      feed.change(msg('c1-new', t: 200));
      feed.changeErrs.add(1);
      final (c, store) = await withCursor();
      await run(c);
      expect((await store.cursor())?.id, cursor.id);
      expect(await store.newest('c1'), hasLength(1), reason: 'only the seed');
    });

    // Group J: a store write that fails stops the pass before the cursor
    // moves, so the rows it could not keep are read again next time.
    test('a failing store write stops the pass before saveCursor; the next '
        'pass retries and moves it', () async {
      feed.change(msg('c1-new', t: 200));
      final (c, store) = await withCursor();
      store.failUpserts = 1;
      await run(c);
      expect(store.calls, contains('upsert-failed'), reason: 'setup');
      expect(store.saved, isEmpty, reason: 'cursor saved past a lost write');
      expect((await store.cursor())?.id, cursor.id);
      expect(ids(await store.newest('c1')), isNot(contains('c1-new')));

      await run(c);
      expect((await store.cursor())?.id, 'c1-new', reason: 'retried');
      expect(ids(await store.newest('c1')), contains('c1-new'));
    });

    test(
      'an Err on a later page keeps the cursor of the last applied page',
      () async {
        final rows = [
          for (var i = 0; i < 600; i++)
            msg('c1-n${i.toString().padLeft(4, '0')}', t: 101 + i),
        ];
        rows.forEach(feed.change);
        feed.changeErrs.add(2);
        final (c, store) = await withCursor();
        await run(c);
        expect((await store.cursor())?.id, rows[499].id);
      },
    );

    test('a run() during a pass restarts it, catch-up first', () async {
      feed.change(msg('c1-new', t: 200));
      feed.history['c3'] = _rows('c3', 0, 5);
      feed.changeGates[1] = Completer<void>();
      final (c, _) = await withCursor();
      // c3 is listed but has no sync state: the pass would fill it.
      feed.conversationsResult = Ok([_chat('c1', 100), _chat('c3', 4)]);
      final sync = c.read(storeSyncProvider);
      final first = sync.run();
      await eventually(() => feed.feedCalls.length == 1, reason: 'held read');
      final second = sync.run();
      feed.changeGates[1]!.complete();
      await Future.wait([first, second]).timeout(const Duration(seconds: 20));
      await eventually(
        () => feed.count('messages:c3') > 0,
        reason: 'the restarted pass fills c3',
      );
      final starts = [
        for (var i = 0; i < feed.calls.length; i++)
          if (feed.calls[i] == 'changesSince') i,
      ];
      expect(
        feed.feedCalls.where((x) => x.id == _nil).length,
        greaterThanOrEqualTo(2),
        reason: 'a second pass started from the overlap again',
      );
      expect(
        starts[1],
        lessThan(feed.calls.indexOf('messages:c3')),
        reason: 'catch-up before the fill',
      );
      expect(
        feed.count('messages:c3'),
        1,
        reason: 'the halted pass did not fill',
      );
    });
  });

  group('nothing happens', () {
    test('when the chat list is offline', () async {
      feed.conversationsResult = const Err(NetworkFailure('offline'));
      feed.change(msg('c1-new', t: 200));
      final c = await boot();
      await run(c);
      expect(feed.count('changesSince'), 0);
      expect(feed.count('newestChange'), 0);
      expect(feed.count('messages:'), 0);
      expect(await storeOf(c).cursor(), isNull);
    });

    test('without a store', () async {
      feed.conversationsResult = Ok([_chat('c1', 1)]);
      final c = await boot(withStore: false);
      await run(c);
      expect(feed.count('changesSince'), 0);
      expect(feed.count('newestChange'), 0);
      expect(feed.count('messages:'), 0);
    });

    for (final s in <SessionState>[
      const SignedOut(),
      const SessionLoading(),
      const Denied(),
    ]) {
      test('when the session is ${s.runtimeType}', () async {
        feed.conversationsResult = Ok([_chat('c1', 1)]);
        feed.history['c1'] = _rows('c1', 0, 3);
        final c = await boot(session: s);
        await run(c);
        expect(feed.count('conversations'), 0);
        expect(feed.count('changesSince'), 0);
        expect(feed.count('newestChange'), 0);
        expect(feed.count('messages:'), 0);
      });
    }
  });

  group('stops mid-pass', () {
    test('an account change: the old store gets nothing more', () async {
      feed.history['c1'] = _rows('c1', 0, 700);
      feed.change(feed.history['c1']!.last);
      feed.conversationsResult = Ok([_chat('c1', 699)]);
      feed.beforeGates[1] = Completer<void>();
      final c = await boot();
      unawaited(c.read(storeSyncProvider).run());
      await eventually(() => feed.beforeCalls.length == 1, reason: 'held');
      (c.read(sessionControllerProvider.notifier) as _Session).become(
        _allowed('other'),
      );
      await eventually(
        () => c.read(currentUserIdProvider) == 'other',
        reason: 'account switched',
      );
      feed.beforeGates[1]!.complete();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(feed.beforeCalls.length, 1, reason: 'no further pages');
      expect(
        opened['other'] ?? const <_Spy>[],
        everyElement(predicate<_Spy>((s) => s.count('extendOlder') == 0)),
        reason: 'the new account store gets none of the old pass',
      );
      // What the old account's file holds: only the newest page.
      final back = reopen('me');
      // The page in flight at the switch lands on nothing: the old store is
      // closed with its provider (the call itself may still be made).
      expect(ids(await back.newest('c1', limit: 1000)), hasLength(50));
      expect((await back.syncState('c1'))!.contiguousFrom?.toUtc(), at(650));
    });

    // The two tests below keep the old store OPEN, so the pass cannot be
    // stopped by writes failing on a closed store: only the controller's own
    // check can stop it.
    Future<ProviderContainer> heldFill(Override store) async {
      feed.history['c1'] = _rows('c1', 0, 700);
      feed.change(feed.history['c1']!.last);
      feed.conversationsResult = Ok([_chat('c1', 699)]);
      feed.beforeGates[1] = Completer<void>();
      final c = await boot(withStore: false, more: [store]);
      unawaited(c.read(storeSyncProvider).run());
      await eventually(() => feed.beforeCalls.length == 1, reason: 'held');
      return c;
    }

    test('an account change stops the pass, the old store left open', () async {
      // One store per account, as main.dart builds it, but never closed.
      final c = await heldFill(
        messageStoreProvider.overrideWith(
          (ref) => _Spy(reopen('${ref.watch(currentUserIdProvider)}'), feed),
        ),
      );
      (c.read(sessionControllerProvider.notifier) as _Session).become(
        _allowed('other'),
      );
      await eventually(
        () => c.read(currentUserIdProvider) == 'other',
        reason: 'account switched',
      );
      feed.beforeGates[1]!.complete();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(feed.beforeCalls.length, 1, reason: 'no further pages');
    });

    test('a replaced store stops the pass, the old one left open', () async {
      var builds = 0;
      final c = await heldFill(
        messageStoreProvider.overrideWith((ref) {
          builds++;
          return _Spy(reopen('me$builds'), feed);
        }),
      );
      c.invalidate(messageStoreProvider);
      c.read(messageStoreProvider);
      expect(builds, 2, reason: 'a new store instance');
      feed.beforeGates[1]!.complete();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(feed.beforeCalls.length, 1, reason: 'no further pages');
    });

    test('a sign-out (erase): nothing is written after it', () async {
      feed.history['c1'] = _rows('c1', 0, 700);
      feed.change(feed.history['c1']!.last);
      feed.conversationsResult = Ok([_chat('c1', 699)]);
      feed.beforeGates[1] = Completer<void>();
      // As main.dart wires it: the drift stores and the session-end eraser.
      final c = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(feed),
          sessionControllerProvider.overrideWith(
            () => _Session(_allowed('me')),
          ),
          ...videoOverrides(),
          ...driftStoreOverrides(h.dir, key),
        ],
      );
      addTearDown(() => quit(c));
      c.listen(currentUserIdProvider, (_, _) {});
      c.listen(chatListSnapshotOwnerProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      unawaited(c.read(storeSyncProvider).run());
      await eventually(() => feed.beforeCalls.length == 1, reason: 'held');
      (c.read(sessionControllerProvider.notifier) as _Session).become(
        const SignedOut(),
      );
      await eventually(
        () => !storeFileIn(h.dir).existsSync(),
        reason: 'store erased at sign-out',
      );
      feed.beforeGates[1]!.complete();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(feed.beforeCalls.length, 1, reason: 'no further pages');
      final back = driftStore('me', h.dir, key);
      addTearDown(back.close);
      expect(await back.newest('c1', limit: 1000), isEmpty);
      expect(await back.syncState('c1'), isNull);
      expect(await back.cursor(), isNull);
    });
  });

  // Halt before every write. The stores here are one per account, as
  // main.dart builds them, but NEVER closed: a write after the halt would
  // land. So only the controller's own checks can keep a stale page out.
  group('halts before a write', () {
    Override openStores() => messageStoreProvider.overrideWith((ref) {
      final uid = ref.watch(currentUserIdProvider) ?? '';
      final s = _Spy(reopen('open-$uid'), feed);
      (opened[uid] ??= []).add(s);
      return s;
    });

    final halts = <String, SessionState>{
      'a sign-out': const SignedOut(),
      'an account switch': _allowed('other'),
    };

    /// Starts a pass on 'me', waits until [inFlight], halts with [to], then
    /// lets [release] go and waits for the pass to end. Returns the old store
    /// and its write count at the halt.
    Future<(_Spy, int)> haltDuring({
      required ProviderContainer c,
      required SessionState to,
      required bool Function() inFlight,
      required void Function() release,
      String what = '',
    }) async {
      final old = storeOf(c);
      final pass = c.read(storeSyncProvider).run();
      await eventually(inFlight, reason: '$what in flight');
      (c.read(sessionControllerProvider.notifier) as _Session).become(to);
      await eventually(
        () => c.read(currentUserIdProvider) != 'me',
        reason: 'session changed',
      );
      final atHalt = old.writes;
      release();
      await pass.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return (old, atHalt);
    }

    void noneElsewhere() {
      for (final MapEntry(:key, :value) in opened.entries) {
        if (key == 'me') continue;
        for (final s in value) {
          expect(s.writes, 0, reason: 'store of "$key" got ${s.calls}');
        }
      }
    }

    /// A fresh store (no cursor) with one chat of 700 rows on the server.
    Future<ProviderContainer> fresh() async {
      feed.history['c1'] = _rows('c1', 0, 700);
      feed.change(feed.history['c1']!.last);
      feed.conversationsResult = Ok([_chat('c1', 699)]);
      return boot(withStore: false, more: [openStores()]);
    }

    /// A complete c1 and a stored cursor, with changes after it.
    Future<ProviderContainer> withCursor() async {
      feed.conversationsResult = Ok([_chat('c1', 300)]);
      final c = await boot(withStore: false, more: [openStores()]);
      final s = storeOf(c);
      await s.reconcilePage('c1', [
        msg('c1-seed', conv: 'c1', t: 1),
      ], reachedStart: true);
      await s.saveCursor(ChangeCursor(at(100), 'c1-seed'));
      for (var i = 0; i < 3; i++) {
        feed.change(msg('c1-n$i', t: 200 + i));
      }
      s.calls.clear();
      s.saved.clear();
      return c;
    }

    for (final MapEntry(key: how, value: to) in halts.entries) {
      test(
        '$how while newestChange is in flight: no cursor, no page',
        () async {
          feed.newestGate = Completer<void>();
          final c = await fresh();
          final (old, atHalt) = await haltDuring(
            c: c,
            to: to,
            what: 'newestChange',
            inFlight: () => feed.count('newestChange') == 1,
            release: feed.newestGate!.complete,
          );
          expect(atHalt, 0);
          expect(
            old.writes,
            0,
            reason: 'old store got ${old.calls} ${old.saved}',
          );
          expect(feed.count('messages:'), 0, reason: 'no fill read');
          noneElsewhere();
        },
      );

      test(
        '$how while changesSince is in flight: no page, no cursor',
        () async {
          feed.changeGates[1] = Completer<void>();
          final c = await withCursor();
          final (old, atHalt) = await haltDuring(
            c: c,
            to: to,
            what: 'changesSince',
            inFlight: () => feed.feedCalls.length == 1,
            release: feed.changeGates[1]!.complete,
          );
          expect(old.writes, atHalt, reason: 'old store got ${old.calls}');
          expect(old.saved, isEmpty, reason: 'cursor saved after the halt');
          expect(feed.feedCalls, hasLength(1), reason: 'no further page');
          noneElsewhere();
        },
      );

      test(
        '$how while a feed page is being written: no cursor saved',
        () async {
          final c = await withCursor();
          final old = storeOf(c)..holdUpsert = Completer<void>();
          final (_, atHalt) = await haltDuring(
            c: c,
            to: to,
            what: 'page write',
            inFlight: () => old.count('upsert:') == 1,
            release: old.holdUpsert!.complete,
          );
          expect(old.writes, atHalt, reason: 'old store got ${old.calls}');
          expect(old.saved, isEmpty, reason: 'cursor saved after the halt');
          noneElsewhere();
        },
      );

      test(
        '$how while a newest page (messages) is in flight: no reconcile',
        () async {
          feed.holdChat = 'c1';
          final c = await fresh();
          final (old, atHalt) = await haltDuring(
            c: c,
            to: to,
            what: 'messages',
            inFlight: () => feed.count('held:c1') == 1,
            release: feed.chatGate.complete,
          );
          expect(old.writes, atHalt, reason: 'old store got ${old.calls}');
          expect(old.count('reconcile:'), 0);
          expect(old.count('extendOlder:'), 0);
          expect(feed.beforeCalls, isEmpty, reason: 'no older page asked for');
          noneElsewhere();
        },
      );

      test('$how while messagesBefore is in flight: no extendOlder', () async {
        feed.beforeGates[1] = Completer<void>();
        final c = await fresh();
        final (old, atHalt) = await haltDuring(
          c: c,
          to: to,
          what: 'messagesBefore',
          inFlight: () => feed.beforeCalls.length == 1,
          release: feed.beforeGates[1]!.complete,
        );
        expect(old.count('reconcile:'), 1, reason: 'the newest page landed');
        expect(old.writes, atHalt, reason: 'old store got ${old.calls}');
        expect(old.count('extendOlder:'), 0);
        expect(feed.beforeCalls, hasLength(1), reason: 'no further pages');
        final back = (await old.syncState('c1'))!;
        expect(back.contiguousFrom?.toUtc(), at(650), reason: 'not lowered');
        noneElsewhere();
      });
    }
  });

  group('open chat loading', () {
    Future<ProviderContainer> openLoading() async {
      feed.history['c1'] = _rows('c1', 0, 5);
      feed.history['c9'] = _rows('c9', 0, 5);
      feed.change(feed.history['c1']!.last);
      feed.conversationsResult = Ok([_chat('c1', 4), _chat('c9', 3)]);
      feed.holdChat = 'c9';
      final c = await boot();
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c9');
      await eventually(() => feed.count('held:c9') > 0, reason: 'c9 loading');
      return c;
    }

    test('delays the fill until the open chat has its first page', () async {
      final c = await openLoading();
      unawaited(c.read(storeSyncProvider).run());
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(feed.count('messages:c1'), 0, reason: 'fill waits');
      feed.chatGate.complete();
      await eventually(
        () => feed.count('messages:c1') > 0,
        reason: 'fill starts once c9 loaded',
        timeout: const Duration(seconds: 2),
      );
    });

    test('waits at most about 3 s', () async {
      final c = await openLoading();
      final clock = Stopwatch()..start();
      unawaited(c.read(storeSyncProvider).run());
      await eventually(
        () => feed.count('messages:c1') > 0,
        reason: 'fill starts without c9',
        timeout: const Duration(seconds: 8),
      );
      expect(clock.elapsed, greaterThan(const Duration(milliseconds: 2500)));
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 5000)));
      feed.chatGate.complete();
    });
  });
}
