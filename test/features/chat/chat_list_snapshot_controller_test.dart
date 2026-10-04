// The stored chat list, as ConversationListController uses it. Written from
// the ChatListSnapshotStore contract, the controller's public API (build /
// refresh / reloadQuietly / markRead), docs/DECISIONS.md 2026-09-29 and the
// "stored chat list" section of docs/SECURITY.md -- never from the
// implementation.
//
// The store is the REAL FileChatListSnapshotStore on a temp directory, behind
// a thin decorator that only logs and can hold a load in flight after the
// disk read, as a slow phone does. The chat fake answers as whoever holds the
// session at call time and can hold each list read open separately, so a
// stale answer can arrive after the account changed.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/file_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const alice = Member(userId: 'u-a', displayName: 'Alice');
const bora = Member(userId: 'u-b', displayName: 'Bora');
const deniz = Member(userId: 'u-d', displayName: 'Deniz');

final t0 = DateTime.utc(2026, 9, 29, 9);

Conversation conv(String id, String text, int minute) => Conversation(
  id: id,
  other: deniz,
  lastMessage: text,
  lastMessageAt: t0.add(Duration(minutes: minute)),
  lastSenderId: deniz.userId,
  unread: 1,
);

/// Alice's list: ids and previews that must never reach Bora.
final aList = [
  conv('a-1', 'secret of alice 1', 2),
  conv('a-2', 'secret of alice 2', 1),
];
final bList = [conv('b-1', 'bora own', 3)];
const aIds = ['a-1', 'a-2'];

/// The session, driven by the test: every state the gate can show.
class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
  void set(SessionState s) => state = AsyncData(s);
}

/// One conversations() call: who asked, held until answered when holding.
class _Call {
  _Call(this.who);
  final String? who;
  final gate = Completer<void>();
  Result<List<Conversation>>? answer;
}

/// The list read answers as whoever held the session when it was ASKED, as
/// the one Supabase client does; with [holding] every read stays in flight
/// until the test answers it.
class ListChat extends FakeChat {
  final byOwner = <String, List<Conversation>>{};
  String? who;
  bool holding = false;

  /// What every read answers when set (a server that refuses or is down).
  Result<List<Conversation>>? failWith;
  final calls = <_Call>[];

  @override
  Future<Result<List<Conversation>>> conversations() async {
    final call = _Call(who);
    calls.add(call);
    await Future<void>.delayed(Duration.zero); // a network call
    if (holding) await call.gate.future;
    return call.answer ?? failWith ?? Ok(byOwner[call.who] ?? const []);
  }

  /// Answers read [i] (in asking order), with its own owner's list by default.
  void answer(int i, [Result<List<Conversation>>? result]) {
    calls[i].answer = result;
    calls[i].gate.complete();
  }

  /// Answers every read still in flight.
  void answerAll([Result<List<Conversation>>? result]) {
    for (var i = 0; i < calls.length; i++) {
      if (!calls[i].gate.isCompleted) answer(i, result);
    }
  }
}

/// The real file store, logged; [holdLoad] keeps a load's answer in flight
/// AFTER the file was read, so the list it read arrives late.
class DiskStore implements ChatListSnapshotStore {
  DiskStore(this.dir)
    : inner = FileChatListSnapshotStore(root: () async => dir);
  final Directory dir;
  final FileChatListSnapshotStore inner;
  final log = <String>[];
  Completer<void>? holdLoad;

  File get file => File('${dir.path}/chat_list.json');

  /// The file's raw text, or null when there is none.
  String? get raw => file.existsSync() ? file.readAsStringSync() : null;

  /// Every save as "owner:id,id".
  List<String> get saves => [
    for (final e in log)
      if (e.startsWith('save:')) e.substring(5),
  ];

  @override
  Future<List<Conversation>?> load(String ownerId) async {
    log.add('load:$ownerId');
    final read = await inner.load(ownerId);
    final hold = holdLoad;
    if (hold != null) await hold.future;
    return read;
  }

  @override
  Future<void> save(String ownerId, List<Conversation> conversations) {
    log.add('save:$ownerId:${conversations.map((c) => c.id).join(',')}');
    return inner.save(ownerId, conversations);
  }

  @override
  Future<void> clear() {
    log.add('clear');
    return inner.clear();
  }
}

/// Lets the controller's async hops run.
Future<void> pause([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Longer than the debounce (docs: a burst costs one write), so any save
/// scheduled has had its chance to land.
Future<void> pastDebounce() => pause(2600);

Future<void> until(bool Function() ok, String what) async {
  for (var i = 0; i < 500; i++) {
    if (ok()) return;
    await pause(20);
  }
  fail('timed out waiting for $what');
}

List<String> idsOf(AsyncValue<List<Conversation>> v) =>
    v.hasValue ? [for (final c in v.value!) c.id] : const [];

bool hasAny(Iterable<String> ids, Iterable<String> needles) =>
    needles.any(ids.contains);

void main() {
  late Directory dir;
  late DiskStore store;
  late ListChat chat;
  late List<AsyncValue<List<Conversation>>> states;

  /// The home screen's hold on the list: open while a member is signed in.
  late ProviderSubscription<AsyncValue<List<Conversation>>> home;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chat-list-ctl-');
    store = DiskStore(dir);
    chat = ListChat()
      ..byOwner[alice.userId] = aList
      ..byOwner[bora.userId] = bList;
    states = [];
  });

  tearDown(() async {
    if (store.holdLoad case final h? when !h.isCompleted) h.complete();
    for (final c in chat.calls) {
      if (!c.gate.isCompleted) c.gate.complete();
    }
    await pause();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Alice's list already on the phone from an earlier run.
  Future<void> seedAlice() =>
      FileChatListSnapshotStore(root: () async => dir)
          .save(alice.userId, aList);

  /// Who the one client answers as. A recheck (SessionLoading) or an
  /// unreachable server (SessionError) does not end the client's session.
  String? whoOf(SessionState s, [String? before]) => switch (s) {
    Allowed(:final member) => member.userId,
    SessionLoading() || SessionError() => before,
    _ => null,
  };

  ProviderSubscription<AsyncValue<List<Conversation>>> watchList(
    ProviderContainer c,
  ) => c.listen(
    conversationListProvider,
    (_, next) => states.add(next),
    fireImmediately: true,
  );

  /// The app as SessionGate mounts it: the erase-on-end provider listened,
  /// the list kept alive for the whole run, the real store injected.
  ProviderContainer app(SessionState initial, {bool mountEraser = true}) {
    chat.who = whoOf(initial);
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        sessionControllerProvider.overrideWith(() => _Session(initial)),
        chatListSnapshotStoreProvider.overrideWithValue(store),
      ],
    );
    if (mountEraser) c.listen(chatListSnapshotOwnerProvider, (_, _) {});
    home = watchList(c);
    return c;
  }

  void session(ProviderContainer c, SessionState s) {
    chat.who = whoOf(s, chat.who);
    (c.read(sessionControllerProvider.notifier) as _Session).set(s);
  }

  AsyncValue<List<Conversation>> list(ProviderContainer c) =>
      c.read(conversationListProvider);

  bool settled(ProviderContainer c) => !list(c).isLoading;

  /// Alice signed in, her server list shown and saved.
  Future<ProviderContainer> aliceLoaded([List<String> ids = aIds]) async {
    final c = app(const Allowed(alice));
    await until(
      () => idsOf(list(c)).join() == ids.join() && !list(c).isLoading,
      "alice's list",
    );
    await until(
      () => store.saves.contains('${alice.userId}:${ids.join(',')}'),
      "alice's snapshot saved",
    );
    // Logged is not written: wait for the file itself.
    await until(
      () => store.raw?.contains('secret of alice 1') ?? false,
      "alice's snapshot on disk",
    );
    return c;
  }

  Message incoming(String conversation, String body) => Message(
    id: 'm-$conversation-$body',
    conversationId: conversation,
    senderId: deniz.userId,
    body: body,
    createdAt: t0.add(const Duration(hours: 1)),
  );

  /// A loaded and saved, signs out (erased), B signs in with B's first read
  /// held in flight: the list's previous value is still A's. As in the
  /// app: the home screen (the list's only listener) goes away on
  /// sign-out and comes back for B; the provider itself lives on.
  Future<ProviderContainer> bFirstLoadInFlight([
    List<String> aliceIds = aIds,
  ]) async {
    final c = await aliceLoaded(aliceIds);
    home.close();
    states.clear(); // from here on, what B's screen is handed
    session(c, const SignedOut());
    await until(() => !store.file.existsSync(), 'the erase');
    chat.holding = true;
    session(c, const SessionLoading());
    await pause();
    session(c, const Allowed(bora));
    home = watchList(c);
    await until(
      () => chat.calls.any((x) => x.who == bora.userId),
      "B's first read",
    );
    return c;
  }

  void expectNoAliceOnDisk() {
    expect(
      store.saves.where((s) => s.startsWith('${bora.userId}:')),
      everyElement(isNot(contains('a-'))),
      reason: "A's list saved under B: ${store.log}",
    );
    expect(
      store.raw ?? '',
      isNot(contains('secret of alice')),
      reason: "B's stored file holds A's list",
    );
  }

  /// B's list state, every value it was handed since A's screen closed and
  /// the one now: none holds A's rows, whatever its kind.
  void expectNoAliceInState(ProviderContainer c) {
    for (final s in [...states, list(c)]) {
      expect(
        hasAny(idsOf(s), aIds),
        isFalse,
        reason: "B's list state holds A's rows: $s",
      );
    }
  }

  group('baseline', () {
    test('a loaded list is saved for its owner, and shown from the phone on '
        'the next start before the server answers', () async {
      await aliceLoaded();
      expect(store.raw, contains('secret of alice 1'));

      // Next app run: the server is slow; the stored list shows first.
      states.clear();
      chat.holding = true;
      final next = app(const Allowed(alice));
      await until(() => idsOf(list(next)).isNotEmpty, 'the stored list');
      expect(idsOf(list(next)), aIds);
      expect(chat.calls.last.gate.isCompleted, isFalse, reason: 'shown early');
    });
  });

  group('1. no snapshot is saved while the session is not settled', () {
    for (final (name, unsettled) in [
      ('SessionLoading', const SessionLoading()),
      ('SessionError', const SessionError('offline')),
    ]) {
      test('cold start on $name: nothing saved, the stored list never '
          'shown', () async {
        await seedAlice();
        final c = app(unsettled);
        await pause(100);
        try {
          await c.read(conversationListProvider.notifier).refresh();
        } catch (_) {}
        await pastDebounce();

        expect(store.saves, isEmpty, reason: 'saved during $name');
        for (final s in states) {
          expect(hasAny(idsOf(s), aIds), isFalse, reason: 'showed $s');
        }
      });

      test('in-run $name: a live message, a quiet reload and a refresh '
          'save nothing', () async {
        final c = await aliceLoaded();
        final before = store.saves.length;

        session(c, unsettled);
        await pause();
        chat.deliver(incoming('a-1', 'while $name'));
        await pause();
        final ctl = c.read(conversationListProvider.notifier);
        try {
          await ctl.reloadQuietly();
        } catch (_) {}
        try {
          await ctl.refresh();
        } catch (_) {}
        await pastDebounce();

        expect(
          store.saves.skip(before),
          isEmpty,
          reason: 'saved while the session was $name',
        );
      });

      test('in-run $name: a save debounced just before it does not land '
          'during it', () async {
        final c = await aliceLoaded();
        final before = store.saves.length;

        chat.deliver(incoming('a-2', 'just before $name'));
        await pause();
        session(c, unsettled);
        await pastDebounce();

        expect(
          store.saves.skip(before),
          isEmpty,
          reason: 'the debounced save fired while the session was $name',
        );
      });
    }

    test(
      'control: a live message while Allowed IS saved (debounced)',
      () async {
        await aliceLoaded();
        final before = store.saves.length;
        chat.deliver(incoming('a-2', 'fresh'));
        await pastDebounce();
        expect(store.saves.length, greaterThan(before));
        expect(store.raw, contains('fresh'));
      },
    );
  });

  group('2. a session found ended erases the stored list', () {
    for (final (name, ended) in [
      ('SignedOut', const SignedOut()),
      ('Denied', const Denied()),
    ]) {
      test('cold start on $name erases it', () async {
        await seedAlice();
        expect(store.file.existsSync(), isTrue);

        final c = app(ended, mountEraser: false);
        // Mounted only once the session has already landed on $name, as a
        // gate built after a fast answer mounts it: the eraser must still
        // see the state it arrived in, not only later changes.
        await c.read(sessionControllerProvider.future);
        await pause();
        c.listen(chatListSnapshotOwnerProvider, (_, _) {});
        await until(() => !store.file.existsSync(), 'the erase');
        expect(store.log, contains('clear'));
      });

      test('$name during the run erases it', () async {
        final c = await aliceLoaded();
        session(c, ended);
        await until(() => !store.file.existsSync(), 'the erase');
        await pastDebounce();
        expect(store.file.existsSync(), isFalse, reason: 're-created');
      });
    }
  });

  group("3. an account never sees another account's stored list", () {
    test("cold start as B over A's file: A's list is never shown, and the "
        'file is gone once B has asked', () async {
      await seedAlice();
      chat.holding = true;
      final c = app(const Allowed(bora));
      await until(() => chat.calls.isNotEmpty, "B's first read");
      await pause(100);
      for (final s in states) {
        expect(hasAny(idsOf(s), aIds), isFalse, reason: 'B saw $s');
      }

      chat.answerAll();
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      await pastDebounce();
      for (final s in states) {
        expect(hasAny(idsOf(s), aIds), isFalse, reason: 'B saw $s');
      }
      expect(store.raw ?? '', isNot(contains('secret of alice')));
      for (final s in store.saves) {
        expect(s, isNot(contains('a-')), reason: 'saved A data: $s');
      }
    });

    test('switching straight from A to B: no settled B state and no save '
        "carries A's list", () async {
      final c = await aliceLoaded();
      chat.holding = true;
      final mark = states.length;
      final savesBefore = store.saves.length;

      session(c, const Allowed(bora));
      await until(() => chat.calls.any((x) => x.who == bora.userId), 'B read');
      chat.answer(chat.calls.indexWhere((x) => x.who == bora.userId));
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      await pastDebounce();

      for (final s in states.skip(mark)) {
        if (s is AsyncData) {
          expect(hasAny(idsOf(s), aIds), isFalse, reason: 'B saw $s');
        }
      }
      for (final s in store.saves.skip(savesBefore)) {
        expect(s, isNot(contains('a-')), reason: 'saved A data: $s');
      }
      expect(store.raw ?? '', isNot(contains('secret of alice')));
    });
  });

  group('4. a load in flight at sign-out does not re-create the file', () {
    test('the stored-list read finishing after the erase', () async {
      await seedAlice();
      store.holdLoad = Completer<void>();
      chat.holding = true;
      final c = app(const Allowed(alice));
      await until(
        () => store.log.contains('load:${alice.userId}'),
        'the stored-list read',
      );

      session(c, const SignedOut());
      await until(() => store.log.contains('clear'), 'the erase');
      await until(() => !store.file.existsSync(), 'the file gone');
      store.holdLoad!.complete();
      chat.answerAll();
      await pastDebounce();

      final cleared = store.log.lastIndexOf('clear');
      expect(
        store.log.skip(cleared).where((e) => e.startsWith('save:')),
        isEmpty,
        reason: 'saved after the erase: ${store.log}',
      );
      expect(store.file.existsSync(), isFalse, reason: 're-created');
    });

    test("the first server read finishing after the erase", () async {
      chat.holding = true;
      final c = app(const Allowed(alice));
      // Alice's own build (not one from before the session settled) has
      // read the phone and asked the server.
      await until(
        () => store.log.contains('load:${alice.userId}'),
        "alice's build",
      );
      await pause(100);
      expect(
        chat.calls.where((x) => !x.gate.isCompleted),
        isNotEmpty,
        reason: "alice's server read is not in flight",
      );

      session(c, const SignedOut());
      await until(() => store.log.contains('clear'), 'the erase');
      chat.answerAll();
      await pastDebounce();

      final cleared = store.log.lastIndexOf('clear');
      expect(
        store.log.skip(cleared).where((e) => e.startsWith('save:')),
        isEmpty,
        reason: 'saved after the erase: ${store.log}',
      );
      expect(store.file.existsSync(), isFalse, reason: 're-created');
    });

    test('a refresh finishing after the erase', () async {
      final c = await aliceLoaded();
      chat.holding = true;
      final refreshing = c.read(conversationListProvider.notifier).refresh();
      await until(() => chat.calls.length >= 2, 'the refresh read');
      final refreshRead = chat.calls.length - 1;

      session(c, const SignedOut());
      await until(() => !store.file.existsSync(), 'the erase');
      chat.answer(refreshRead);
      await pause(100);
      chat.answerAll();
      try {
        await refreshing;
      } catch (_) {}
      await pastDebounce();

      expect(store.file.existsSync(), isFalse, reason: 're-created');
    });
  });

  // 0.30.16 (offline start): the stored list stays on screen on ANY load
  // failure but a refusal, with the stale flag up and the file untouched.
  group('7. the stored list stays on any load failure but a refusal', () {
    bool stale(ProviderContainer c) => c.read(conversationListStaleProvider);
    ConversationListController ctl(ProviderContainer c) =>
        c.read(conversationListProvider.notifier);

    Future<ProviderContainer> coldStart(Failure f, {bool seed = true}) async {
      if (seed) await seedAlice();
      final before = store.raw;
      chat.failWith = Err(f);
      final c = app(const Allowed(alice));
      await until(() => chat.calls.isNotEmpty, 'the read');
      await until(() => settled(c) && list(c) is! AsyncLoading, 'settled');
      await pause(100);
      expect(store.raw, before, reason: 'fixture: nothing written yet');
      return c;
    }

    Future<void> tryRefresh(ProviderContainer c) async {
      try {
        await ctl(c).refresh();
      } catch (_) {}
      await until(() => settled(c), 'settled');
      await pause(100);
    }

    for (final (name, failure) in [
      (
        'a retryable NetworkFailure',
        const NetworkFailure('o', retryable: true),
      ),
      ('a non-retryable NetworkFailure', const NetworkFailure('refused')),
      ('a ProviderFailure', const ProviderFailure('boom')),
    ]) {
      test('cold start, $name: the stored list, stale, the file not '
          'rewritten', () async {
        final c = await coldStart(failure);
        final raw = store.raw;
        expect(
          list(c),
          isA<AsyncData<List<Conversation>>>(),
          reason: '${list(c)}',
        );
        expect(idsOf(list(c)), aIds);
        expect(stale(c), isTrue);
        await pastDebounce();
        expect(store.saves, isEmpty, reason: '${store.log}');
        expect(store.raw, raw);
      });

      test('refresh, $name, a list on screen: loading, then the same list, '
          'stale, not saved', () async {
        final c = await aliceLoaded();
        await pastDebounce();
        final saves = store.saves.length;
        expect(stale(c), isFalse, reason: 'fixture');
        states.clear();
        chat.failWith = Err(failure);
        await tryRefresh(c);
        expect(states.first.isLoading, isTrue, reason: '$states');
        expect(
          list(c),
          isA<AsyncData<List<Conversation>>>(),
          reason: '${list(c)}',
        );
        expect(idsOf(list(c)), aIds);
        expect(stale(c), isTrue);
        await pastDebounce();
        expect(store.saves, hasLength(saves), reason: '${store.log}');
      });
    }

    test('cold start, Denied, with a stored list: an error', () async {
      final c = await coldStart(const DeniedFailure());
      expect(list(c).hasError, isTrue, reason: '${list(c)}');
      expect(list(c).error, isA<DeniedFailure>());
    });

    test('cold start, offline, no stored list: an error', () async {
      final c = await coldStart(
        const NetworkFailure('o', retryable: true),
        seed: false,
      );
      expect(list(c).hasError, isTrue, reason: '${list(c)}');
      expect(list(c).error, isA<NetworkFailure>());
    });

    test('refresh, Denied, a list on screen: an error, not stale', () async {
      final c = await coldStart(const NetworkFailure('o', retryable: true));
      expect(stale(c), isTrue, reason: 'fixture');
      chat.failWith = const Err(DeniedFailure());
      await tryRefresh(c);
      expect(list(c).hasError, isTrue, reason: '${list(c)}');
      expect(list(c).error, isA<DeniedFailure>());
      expect(stale(c), isFalse);
    });

    test('refresh, offline, no list on screen: an error, not stale', () async {
      final c = await coldStart(
        const NetworkFailure('o', retryable: true),
        seed: false,
      );
      expect(list(c).hasError, isTrue, reason: 'fixture');
      await tryRefresh(c);
      expect(list(c).hasError, isTrue, reason: '${list(c)}');
      expect(stale(c), isFalse);
    });

    test('a successful refresh: the new list, not stale, saved', () async {
      final c = await coldStart(const NetworkFailure('o', retryable: true));
      chat.failWith = null;
      chat.byOwner[alice.userId] = [conv('a-3', 'new', 9)];
      await tryRefresh(c);
      expect(idsOf(list(c)), ['a-3']);
      expect(stale(c), isFalse);
      await until(
        () => store.saves.contains('${alice.userId}:a-3'),
        'the new list saved',
      );
    });

    for (final (name, read) in [
      ('reloadQuietly', (ConversationListController n) => n.reloadQuietly()),
      ('the resume catch-up', (ConversationListController n) => n.catchUp()),
    ]) {
      test('a later successful $name clears the flag', () async {
        final c = await coldStart(const NetworkFailure('o', retryable: true));
        expect(stale(c), isTrue, reason: 'fixture');
        chat.failWith = null;
        chat.byOwner[alice.userId] = [conv('a-3', 'new', 9)];
        await read(ctl(c));
        await until(() => idsOf(list(c)).join() == 'a-3', 'the new list');
        expect(stale(c), isFalse);
      });
    }

    test('a failed quiet reload keeps the flag up', () async {
      final c = await coldStart(const NetworkFailure('o', retryable: true));
      await ctl(c).reloadQuietly();
      await pause(100);
      expect(idsOf(list(c)), aIds);
      expect(stale(c), isTrue);
    });

    // The flag means "the list on screen is the saved one"; with no list on
    // screen there is nothing saved being shown (the provider's own doc, and
    // refresh's "no list on screen: flag false").
    for (final (name, read) in [
      ('reloadQuietly', (ConversationListController n) => n.reloadQuietly()),
      ('the resume catch-up', (ConversationListController n) => n.catchUp()),
    ]) {
      test('a failed $name with no list on screen: not stale', () async {
        final c = await coldStart(
          const NetworkFailure('o', retryable: true),
          seed: false,
        );
        expect(list(c).hasError, isTrue, reason: 'fixture');
        await read(ctl(c));
        await pause(100);
        expect(list(c).hasError, isTrue, reason: '${list(c)}');
        expect(stale(c), isFalse);
      });
    }

    test('another account does not inherit the flag', () async {
      final c = await coldStart(const NetworkFailure('o', retryable: true));
      expect(stale(c), isTrue, reason: 'fixture');
      chat.failWith = null;
      chat.holding = true; // B's first read stays in flight
      session(c, const SignedOut());
      await pause();
      session(c, const Allowed(bora));
      await until(
        () => chat.calls.any((x) => x.who == bora.userId),
        "B's first read",
      );
      expect(stale(c), isFalse, reason: "B's load in flight");
      chat.answerAll();
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      expect(stale(c), isFalse);
    });
  });

  // 0.30.16: a build replaced by a newer one (A's, after the switch to B)
  // never writes the stale flag, true or false; B's flag is B's alone.
  group("12. A's late build never sets B's stale flag", () {
    bool stale(ProviderContainer c) => c.read(conversationListStaleProvider);
    // The newest read asked as [who]: the read of that owner's own build
    // (a build before the session settled may have asked first).
    int readOf(String who) => chat.calls.lastIndexWhere((x) => x.who == who);

    /// A's cold start over A's stored list, its server read held; then
    /// straight to B, whose first read is held too.
    Future<ProviderContainer> aHeldThenB() async {
      await seedAlice();
      chat.holding = true;
      final c = app(const Allowed(alice));
      await until(() => readOf(alice.userId) >= 0, "A's read");
      await until(() => idsOf(list(c)).join() == aIds.join(), "A's stored");
      session(c, const Allowed(bora));
      await until(() => readOf(bora.userId) >= 0, "B's read");
      return c;
    }

    test("A's late build failing does not raise B's flag", () async {
      final c = await aHeldThenB();
      chat.answer(readOf(bora.userId));
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      expect(stale(c), isFalse, reason: 'fixture');
      // A's build would fall back to A's stored list and raise the flag.
      chat.answer(
        readOf(alice.userId),
        const Err(NetworkFailure('o', retryable: true)),
      );
      await pause(100);
      expect(stale(c), isFalse);
      expect(idsOf(list(c)), ['b-1']);
    });

    test("A's late build succeeding does not clear B's flag", () async {
      final c = await aHeldThenB();
      chat.answer(readOf(bora.userId));
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      // B's own refresh fails with B's list on screen: B's flag is up.
      final before = chat.calls.length;
      final refreshing = c.read(conversationListProvider.notifier).refresh();
      await until(() => chat.calls.length > before, "B's refresh read");
      chat.answer(before, const Err(NetworkFailure('o', retryable: true)));
      try {
        await refreshing;
      } catch (_) {}
      await until(() => settled(c), 'settled');
      expect(stale(c), isTrue, reason: "fixture: B's failed refresh");
      // A's build would clear it on success.
      chat.answer(readOf(alice.userId));
      await pause(100);
      expect(stale(c), isTrue);
      expect(idsOf(list(c)), ['b-1']);
    });
  });

  group('8. an owner swap mid-refresh never saves the result under the new '
      'owner', () {
    for (final staleLast in [true, false]) {
      test("A's refresh answered ${staleLast ? 'after' : 'before'} B's first "
          'read', () async {
        final c = await aliceLoaded();
        chat.holding = true;
        final refreshing = c.read(conversationListProvider.notifier).refresh();
        await until(() => chat.calls.length >= 2, "A's refresh read");
        final aRead = chat.calls.length - 1;
        expect(chat.calls[aRead].who, alice.userId);

        session(c, const Allowed(bora));
        await until(
          () => chat.calls.any((x) => x.who == bora.userId),
          "B's read",
        );
        final bRead = chat.calls.indexWhere((x) => x.who == bora.userId);
        if (staleLast) {
          chat.answer(bRead);
          await pause(100);
          chat.answer(aRead);
        } else {
          chat.answer(aRead);
          await pause(100);
          chat.answer(bRead);
        }
        try {
          await refreshing;
        } catch (_) {}
        await pastDebounce();

        for (final s in store.saves.where(
          (s) => s.startsWith('${bora.userId}:'),
        )) {
          expect(s, isNot(contains('a-')), reason: "A's list saved as B: $s");
        }
        expect(store.raw ?? '', isNot(contains('secret of alice')));
        expect(idsOf(list(c)), ['b-1']);
      });
    }
  });

  group("10. saved only from a settled result of the current owner: B's file "
      "never holds A's list (A, sign-out, B in one run)", () {
    test("(e) B's first load in flight: B's state holds none of A's rows "
        'in any form, its loading value included', () async {
      final c = await bFirstLoadInFlight();
      await pause(100);
      expectNoAliceInState(c);
      chat.answerAll();
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      expectNoAliceInState(c);
    });

    test("(f) B's first load in flight: the readers of the list's in-memory "
        "value -- the chat search's row labels and a profile page's 1:1 "
        "lookup -- find none of A's conversations", () async {
      final c = await bFirstLoadInFlight();
      await pause(100);
      // As the two screens read it: the provider's current value, whatever
      // the state's kind.
      final value = list(c).value ?? const <Conversation>[];
      final labels = {for (final x in value) x.id: x};
      expect(
        labels.keys,
        isNot(anyOf(contains('a-1'), contains('a-2'))),
        reason: "search results would be labelled with A's conversations",
      );
      // a-1 is A's own 1:1 with Deniz: B opening Deniz's profile must not
      // be offered it.
      final direct = value
          .where((x) => !x.isGroup && x.other?.userId == deniz.userId)
          .firstOrNull;
      expect(
        direct?.id,
        isNot(startsWith('a-')),
        reason: "B's profile page for Deniz finds A's conversation",
      );
    });

    test('(c) markRead during it, the debounced save firing while the '
        'load is still in flight', () async {
      final c = await bFirstLoadInFlight();
      try {
        await c.read(conversationListProvider.notifier).markRead('a-1');
      } catch (_) {}
      await pastDebounce();
      expectNoAliceOnDisk();
      chat.answerAll();
      await until(() => idsOf(list(c)).join() == 'b-1', "B's list");
      await pastDebounce();
      expectNoAliceOnDisk();
    });

    for (final failure in [
      const NetworkFailure('offline', retryable: true),
      const NetworkFailure('refused'),
    ]) {
      final kind = failure.retryable ? 'retryable' : 'non-retryable';

      test('(a) a quiet reload failing ($kind) during it', () async {
        final c = await bFirstLoadInFlight();
        chat.holding = false;
        chat.failWith = Err(failure);
        try {
          await c.read(conversationListProvider.notifier).reloadQuietly();
        } catch (_) {}
        await pastDebounce();
        expectNoAliceOnDisk();

        chat.answerAll(Err(failure));
        await pastDebounce();
        expectNoAliceOnDisk();
      });

      test('(b) markRead during it, then the load failing ($kind)', () async {
        final c = await bFirstLoadInFlight();
        try {
          await c.read(conversationListProvider.notifier).markRead('a-1');
        } catch (_) {}
        chat.answerAll(Err(failure));
        await pastDebounce();
        expectNoAliceOnDisk();
      });
    }
  });

  group("11. B's second load in flight (an unknown buffered message): a live "
      "event in a conversation A and B share never puts A's list on B's "
      'disk or screen', () {
    /// The conversation A and B are both in: B's Realtime delivers its
    /// events, and A's carried-over list also has a row for it.
    final shared = conv('s-1', 'shared hello', 0);
    const aWithShared = ['a-1', 'a-2', 's-1'];

    /// Someone starts a conversation with B during B's first read.
    final hello = incoming('x-9', 'hello bora');

    setUp(() {
      chat.byOwner[alice.userId] = [...aList, shared];
      chat.byOwner[bora.userId] = [...bList, shared];
    });

    /// A, sign-out, B; B's first read is answered without x-9 (its
    /// snapshot predates it) while x-9's message was buffered, so the
    /// controller reads again. Returns with that second read held.
    Future<(ProviderContainer, int)> bSecondLoadInFlight() async {
      final c = await bFirstLoadInFlight(aWithShared);
      final first = chat.calls.indexWhere((x) => x.who == bora.userId);
      chat.deliver(hello);
      await pause();
      chat.byOwner[bora.userId] = [
        conv('x-9', 'hello bora', 60),
        ...bList,
        shared,
      ];
      final asked = chat.calls.length;
      chat.answer(first, Ok([...bList, shared]));
      await until(
        () => chat.calls.skip(asked).any((x) => x.who == bora.userId),
        "B's second load (for the unknown buffered x-9)",
      );
      final second = chat.calls.lastIndexWhere((x) => x.who == bora.userId);
      await pause(100);
      expect(chat.calls[second].gate.isCompleted, isFalse);
      return (c, second);
    }

    /// The live events, each as Realtime carries it for s-1.
    final events = <String, (Message, String?)>{
      '(a) a NEW message': (incoming('s-1', 'live new'), 'live new'),
      '(b) an EDIT of its newest message': (
        Message(
          id: 'm-s-1-last',
          conversationId: 's-1',
          senderId: deniz.userId,
          body: 'shared, edited',
          createdAt: shared.lastMessageAt!,
          editedAt: t0.add(const Duration(hours: 1)),
        ),
        'shared, edited',
      ),
      '(c) a DELETION (a quiet reload)': (
        Message(
          id: 'm-s-1-last',
          conversationId: 's-1',
          senderId: deniz.userId,
          body: '',
          createdAt: shared.lastMessageAt!,
          deletion: MessageDeletion.placeholder,
        ),
        null,
      ),
    };

    /// What B is handed: never a settled A list, never A's list with B's
    /// live event applied to it, and not A's list once B's load is over.
    void expectBNeverShownAlice(ProviderContainer c, String? applied) {
      for (final s in states) {
        if (!hasAny(idsOf(s), aIds)) continue;
        expect(
          s,
          isNot(isA<AsyncData<List<Conversation>>>()),
          reason: "B's list settled on A's rows: $s",
        );
        final row = s.value!.where((x) => x.id == 's-1').firstOrNull;
        expect(
          row?.lastMessage,
          isNot(applied ?? '\u0000'),
          reason: "B's live event applied to A's carried-over list: $s",
        );
      }
    }

    test("(e) B's second load in flight: B's state holds none of A's rows "
        'in any form', () async {
      final (c, second) = await bSecondLoadInFlight();
      expectNoAliceInState(c);
      chat.answer(second);
      await until(
        () => settled(c) && idsOf(list(c)).contains('x-9'),
        "B's settled list with x-9",
      );
      expectNoAliceInState(c);
    });

    // Owner decision (2026-09-29): once the owner changes, the previous
    // owner's rows are unreachable from the list's state in any form --
    // not AsyncData, not AsyncLoading's value, not AsyncError's value.
    for (final failure in [
      const NetworkFailure('offline', retryable: true),
      const NetworkFailure('refused'),
    ]) {
      final kind = failure.retryable ? 'retryable' : 'non-retryable';
      test("(d) no live event, the second load failing ($kind): B's error does "
          "not carry A's rows", () async {
        final (c, _) = await bSecondLoadInFlight();
        chat.answerAll(Err(failure));
        await pastDebounce();
        expect(
          hasAny(idsOf(list(c)), aIds),
          isFalse,
          reason: "B is left on A's list: ${list(c)}",
        );
      });
    }

    for (final MapEntry(key: what, value: (event, applied)) in events.entries) {
      for (final failure in [
        const NetworkFailure('offline', retryable: true),
        const NetworkFailure('refused'),
      ]) {
        final kind = failure.retryable ? 'retryable' : 'non-retryable';
        // Only a deletion starts a reload of its own; its failure can land
        // before or after the second load's.
        for (final reloadLast in applied == null ? [false, true] : [false]) {
          final order = applied == null
              ? (reloadLast
                    ? ', the reload failing after it'
                    : ', the reload failing before it')
              : '';

          /// [what] arrives while B's second load is held; a quiet reload
          /// it starts and the second load both fail, in [reloadLast]
          /// order. [check] runs after each failure, once the debounced
          /// save has had its chance.
          Future<void> run(void Function(ProviderContainer) check) async {
            final (c, second) = await bSecondLoadInFlight();
            chat.deliver(event);
            await pause(100);
            final reloads = [
              for (var i = second + 1; i < chat.calls.length; i++) i,
            ];
            if (applied == null) {
              expect(reloads, isNotEmpty, reason: 'the deletion reloads');
            }
            void failReloads() {
              for (final i in reloads) {
                if (!chat.calls[i].gate.isCompleted) {
                  chat.answer(i, Err(failure));
                }
              }
            }

            if (!reloadLast) failReloads();
            await pastDebounce();
            check(c);
            chat.answer(second, Err(failure)); // the second load fails
            await pastDebounce();
            check(c);
            failReloads();
            await pastDebounce();
            check(c);
          }

          test("$what during it, then the load failing ($kind)$order: "
              "B's file never holds A's list", () async {
            await run((_) => expectNoAliceOnDisk());
          });

          test("(d) $what during it, then the load failing ($kind)$order: "
              "B is never shown A's list as settled or updated", () async {
            await run((c) => expectBNeverShownAlice(c, applied));
          });
        }
      }

      test('control: $what once B has settled is applied and saved', () async {
        final (c, _) = await bSecondLoadInFlight();
        chat.holding = false;
        chat.answerAll();
        await until(
          () => settled(c) && idsOf(list(c)).contains('x-9'),
          "B's settled list with x-9",
        );
        await pastDebounce();
        final before = store.saves.length;
        if (applied == null) {
          // The server's list after the deletion.
          chat.byOwner[bora.userId] = [
            conv('x-9', 'hello bora', 60),
            ...bList,
            conv('s-1', 'shared after delete', 0),
          ];
        }
        final want = applied ?? 'shared after delete';

        chat.deliver(event);
        await until(
          () => list(c).value?.any((x) => x.lastMessage == want) ?? false,
          'the event on B\'s list',
        );
        await pastDebounce();

        expect(store.saves.skip(before), isNotEmpty, reason: 'not saved');
        expect(store.saves.last, startsWith('${bora.userId}:'));
        expect(store.raw, contains(want));
        expectNoAliceOnDisk();
      });
    }
  });
}
