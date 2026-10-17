// Erasure at session end, with the stores wired as lib/main.dart mounts them
// (a REAL DriftMessageStore per signed-in user over one file, the REAL
// StoreKey over the secure-storage test mock, DriftChatListSnapshotStore over
// that store). From the Private Chats step 1 Group B contract and the
// security gate's items (a)-(c):
// - SignedOut / Denied / Replaced: snapshot cleared first, then the message
//   store, then the provider invalidated; db, -wal, -shm, -journal gone, key
//   deleted; a later read is a fresh, empty instance; a failed first open is
//   not cached.
// - (a) any call after clear() leaves no file and no key;
// - (b) ownerId '' never creates a file or a key;
// - (c) a late call on the OLD instance after sign-out leaves no file.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/chat/domain/chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _ann = Member(userId: 'ann', displayName: 'Ann');

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
  void set(SessionState s) => state = AsyncData(s);
}

/// Logs into [log] so the order of the two clears can be checked.
class _LoggedSnapshot implements ChatListSnapshotStore {
  _LoggedSnapshot(this.inner, this.log);
  final ChatListSnapshotStore inner;
  final List<String> log;
  @override
  Future<List<Conversation>?> load(String ownerId) => inner.load(ownerId);
  @override
  Future<void> save(String ownerId, List<Conversation> c) =>
      inner.save(ownerId, c);
  @override
  Future<void> clear() async {
    log.add('snapshot.clear');
    await inner.clear();
    log.add('snapshot.cleared');
  }
}

class _LoggedStore extends SpyStore {
  _LoggedStore(super.inner, this.log);
  final List<String> log;
  @override
  Future<void> clear() async {
    log.add('store.clear');
    await super.clear();
    log.add('store.cleared');
  }
}

void main() {
  late StoreHarness h;

  setUp(() async {
    h = await StoreHarness.create();
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<Map<String, String>> keys() => const FlutterSecureStorage().readAll();
  File journal() => File('${h.file.path}-journal');
  void expectNoFiles(String why) {
    for (final f in [h.file, h.wal, h.shm, journal()]) {
      expect(f.existsSync(), isFalse, reason: '$why: ${f.path}');
    }
  }

  DriftMessageStore realStore(String owner) => DriftMessageStore(
    ownerId: owner,
    file: () async => h.file,
    key: const StoreKey().loadOrCreate,
    deleteKey: const StoreKey().delete,
  );

  Future<void> everyCall(MessageStore s) async {
    final m = msg('x1', t: 1);
    await s.upsertAll([m]);
    await s.reconcilePage('c1', [m], reachedStart: false);
    await s.newest('c1');
    await s.older('c1', at(5));
    await s.around('c1', 'x1');
    await s.search('hello');
    await s.syncState('c1');
    await s.saveCursor(ChangeCursor(at(1), 'x1'));
    await s.cursor();
    await s.remove('x1');
    await s.deleteConversation('c1');
  }

  group('session end, wired as main.dart', () {
    late List<String> log;
    late List<DriftMessageStore> built;
    late ProviderContainer c;

    _Session session() =>
        c.read(sessionControllerProvider.notifier) as _Session;

    ProviderContainer app({bool watchUser = true}) {
      log = [];
      built = [];
      final container = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(ChatFake()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          sessionControllerProvider.overrideWith(
            () => _Session(const Allowed(_ann)),
          ),
          messageStoreProvider.overrideWith((ref) {
            final owner = watchUser
                ? ref.watch(currentUserIdProvider) ?? ''
                : 'ann';
            final s = realStore(owner);
            ref.onDispose(s.close);
            built.add(s);
            log.add('build:$owner');
            return _LoggedStore(s, log);
          }),
          chatListSnapshotStoreProvider.overrideWith(
            (ref) => _LoggedSnapshot(
              DriftChatListSnapshotStore(
                (ref.watch(messageStoreProvider) as SpyStore).inner
                    as DriftMessageStore,
              ),
              log,
            ),
          ),
        ],
      );
      container.listen(chatListSnapshotOwnerProvider, (_, _) {});
      return container;
    }

    Future<void> signedInWithData() async {
      await c.read(sessionControllerProvider.future);
      await eventually(() => c.read(currentUserIdProvider) == 'ann');
      final s = c.read(messageStoreProvider);
      await s.upsertAll([msg('m1', t: 1), msg('m2', t: 2)]);
      await c.read(chatListSnapshotStoreProvider).save('ann', const [
        Conversation(id: 'c1'),
      ]);
      expect(h.file.existsSync(), isTrue, reason: 'fixture: db written');
      expect(await keys(), isNotEmpty, reason: 'fixture: key made');
    }

    for (final (name, end) in [
      ('SignedOut', const SignedOut()),
      ('Denied', const Denied()),
      ('Replaced', const Replaced(userId: 'other')),
    ]) {
      test('$name: snapshot then store cleared, files and key gone', () async {
        c = app();
        await signedInWithData();
        session().set(end);
        await eventually(() => log.contains('store.cleared'));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final snap = log.indexOf('snapshot.clear');
        final storeClear = log.indexOf('store.clear');
        expect(snap, isNonNegative, reason: 'snapshot cleared');
        expect(storeClear, greaterThan(snap), reason: 'snapshot first');
        expect(log.indexOf('snapshot.cleared'), lessThan(storeClear));
        expectNoFiles(name);
        expect(await keys(), isEmpty, reason: 'key deleted');
      });
    }

    test('the provider is invalidated only after the store clear finished; '
        'the next read is a fresh, empty instance', () async {
      c = app(watchUser: false); // only the invalidation can rebuild it
      await signedInWithData();
      final old = c.read(messageStoreProvider) as _LoggedStore;
      old.holdClear = Completer<void>();
      session().set(const SignedOut());
      await eventually(() => log.contains('store.clear'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        identical(c.read(messageStoreProvider), old),
        isTrue,
        reason: 'not invalidated while the clear is running',
      );

      old.holdClear!.complete();
      await eventually(
        () => !identical(c.read(messageStoreProvider), old),
        reason: 'invalidated after the clear',
      );
      expect(log.where((e) => e.startsWith('build:')), hasLength(2));
      final fresh = c.read(messageStoreProvider);
      expect(await fresh.newest('c1'), isEmpty);
      expect(await fresh.syncState('c1'), isNull);
    });

    test(
      '(c) a late call on the old instance after sign-out leaves no file',
      () async {
        c = app();
        await signedInWithData();
        final old = c.read(messageStoreProvider);
        session().set(const SignedOut());
        await eventually(() => log.contains('store.cleared'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expectNoFiles('after erase');

        expect(
          ids(await old.newest('c1')),
          isEmpty,
          reason:
              'the old instance must be closed, not still serving the '
              "previous account's rows",
        );
        await everyCall(old);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expectNoFiles('late call on the old instance');
        expect(await keys(), isEmpty, reason: 'no key re-created');
      },
    );
  });

  group('store level', () {
    test('a failed first open is not cached: the next call retries', () async {
      var fail = true;
      final s = DriftMessageStore(
        ownerId: 'ann',
        file: () async => h.file,
        key: () async {
          if (fail) throw StateError('keystore locked');
          return const StoreKey().loadOrCreate();
        },
        deleteKey: const StoreKey().delete,
      );
      expect(await s.newest('c1'), isEmpty, reason: 'failure is empty');
      fail = false;
      await s.upsertAll([msg('m1', t: 1)]);
      expect(ids(await s.newest('c1')), ['m1'], reason: 'retried the open');
    });

    test('clear deletes db, -wal, -shm, -journal and the key', () async {
      final s = realStore('ann');
      await s.upsertAll([msg('m1', t: 1)]);
      await journal().writeAsString('leftover');
      await s.clear();
      expectNoFiles('clear');
      expect(await keys(), isEmpty);
    });

    test(
      '(a) any call after clear() finished leaves no file and no key',
      () async {
        final s = realStore('ann');
        await s.upsertAll([msg('m1', t: 1)]);
        await s.clear();
        await everyCall(s);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expectNoFiles('call after clear');
        expect(await keys(), isEmpty, reason: 'no key re-created');
      },
    );

    test("(b) ownerId '' never creates a file or a key", () async {
      final s = realStore('');
      await everyCall(s);
      final snap = DriftChatListSnapshotStore(s);
      await snap.save('', const [Conversation(id: 'c1')]);
      await snap.load('');
      await snap.clear();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expectNoFiles("owner ''");
      expect(await keys(), isEmpty, reason: "owner '' made a key");
    });
  });

  group('round 2: conversationIds and close', () {
    test('conversationIds: every chat with messages, a sync state or a list '
        'row; a deleted one is gone', () async {
      final s = realStore('ann');
      expect(await s.conversationIds(), isEmpty, reason: 'fresh store');
      await s.upsertAll([msg('m1', conv: 'c1', t: 1)]);
      await s.reconcilePage('c2', const [], reachedStart: true);
      await DriftChatListSnapshotStore(s)
          .save('ann', const [Conversation(id: 'c3')]);
      expect(await s.conversationIds(), {'c1', 'c2', 'c3'});
      await s.deleteConversation('c1');
      expect(await s.conversationIds(), isNot(contains('c1')));
    });

    test('an instance whose file another instance erased serves and writes '
        'nothing', () async {
      final a = realStore('ann');
      await a.upsertAll([msg('m1', t: 1)]);
      await realStore('ann').clear(); // another instance erases the file
      expectNoFiles('fixture: erased');
      expect(await a.newest('c1'), isEmpty, reason: 'stale rows served');
      await a.upsertAll([msg('m2', t: 2)]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expectNoFiles('stale instance wrote');
    });

    test('close ends the instance and deletes nothing; later calls write '
        'nothing', () async {
      final s = realStore('ann');
      await s.upsertAll([msg('m1', t: 1)]);
      final keyBefore = await keys();
      await s.close();
      expect(h.file.existsSync(), isTrue, reason: 'close deletes nothing');
      expect(await keys(), keyBefore, reason: 'close keeps the key');
      expect(await s.newest('c1'), isEmpty, reason: 'closed: fallback');
      await s.upsertAll([msg('m2', t: 2)]);

      final again = realStore('ann');
      expect(ids(await again.newest('c1')), [
        'm1',
      ], reason: 'm1 kept; m2 written after close must not be');
    });
  });

  // Fix round 2 contract: an erase on ANY instance wins over an open that
  // began before it; nothing is left and nothing is served afterwards.
  group('fix round 2: an open across an erase', () {
    /// A store whose open is held at [where] ('file' or 'key') until [gate]
    /// completes; [failFirstKey] makes the first key read throw.
    DriftMessageStore held(
      Completer<void> gate,
      String where, {
      bool failFirstKey = false,
    }) {
      var keyCalls = 0;
      var armed = !failFirstKey;
      return DriftMessageStore(
        ownerId: 'ann',
        file: () async {
          if (armed && where == 'file') await gate.future;
          return h.file;
        },
        key: () async {
          keyCalls++;
          if (failFirstKey && keyCalls == 1) {
            armed = true;
            throw StateError('keystore locked');
          }
          if (armed && where == 'key') await gate.future;
          return const StoreKey().loadOrCreate();
        },
        deleteKey: const StoreKey().delete,
      );
    }

    for (final where in ['file', 'key']) {
      for (final retry in [false, true]) {
        for (final eraser in ['another instance', 'the same instance']) {
          for (final part in ['no file and no rows', 'no key']) {
            final what = retry
                ? 'the retry after a failed first open'
                : 'the first open';
            test('$what held at its $where step, an erase on $eraser, then '
                'released: $part', () async {
              await realStore('ann').upsertAll([msg('m0', t: 0)]); // a file
              final gate = Completer<void>();
              final a = held(gate, where, failFirstKey: retry);
              if (retry) {
                expect(await a.newest('c1'), isEmpty, reason: 'failed open');
              }
              final writing = a.upsertAll([msg('m1', t: 1)]);
              final reading = a.newest('c1');
              await Future<void>.delayed(const Duration(milliseconds: 50));
              final erase = eraser == 'another instance'
                  ? realStore('ann').clear()
                  : a.clear();
              if (eraser == 'another instance') {
                await erase; // the erase has fully finished before the release
              } else {
                // The instance's own erase may wait for its open; release it.
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
              gate.complete();
              await erase;
              await writing;
              expect(await reading, isEmpty, reason: 'in-flight read served');
              expect(await a.newest('c1'), isEmpty, reason: 'rows served');
              await a.upsertAll([msg('m2', t: 2)]);
              await Future<void>.delayed(const Duration(milliseconds: 200));
              if (part == 'no key') {
                expect(await keys(), isEmpty, reason: 'key re-created');
              } else {
                expectNoFiles('open across the erase');
              }
            });
          }
        }
      }
    }

    test('erasures rises on every clear, on any instance', () async {
      final a = realStore('ann');
      final before = a.erasures;
      await realStore('ann').clear();
      expect(a.erasures, before + 1, reason: 'process-wide');
      await a.clear();
      expect(realStore('bob').erasures, before + 2);
    });
  });

  group('round 2 (N1): the Android feed at sign-out', () {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> log;
    late ProviderContainer c;
    Completer<void>? annFile;
    var follow = true;

    File feed() => File('${h.dir.path}/chat_list.json');
    File feedPart() => File('${h.dir.path}/chat_list.json.part');

    setUp(() {
      annFile = null;
      follow = true;
      messenger().setMockMethodCallHandler(
        pathChannel,
        (call) async =>
            call.method == 'getApplicationSupportDirectory' ? h.dir.path : null,
      );
      addTearDown(
        () => messenger().setMockMethodCallHandler(pathChannel, null),
      );
      log = [];
      c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(ChatFake()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          sessionControllerProvider.overrideWith(
            () => _Session(const Allowed(_ann)),
          ),
          messageStoreProvider.overrideWith((ref) {
            // follow: false keeps one instance until it is invalidated.
            final owner = follow
                ? ref.watch(currentUserIdProvider) ?? ''
                : 'ann';
            final s = DriftMessageStore(
              ownerId: owner,
              file: () async {
                // Instance A's first database step can be held open.
                final gate = owner == 'ann' ? annFile : null;
                if (gate != null) await gate.future;
                return h.file;
              },
              key: const StoreKey().loadOrCreate,
              deleteKey: const StoreKey().delete,
            );
            ref.onDispose(s.close);
            return _LoggedStore(s, log);
          }),
          chatListSnapshotStoreProvider.overrideWith(
            (ref) => _LoggedSnapshot(
              DriftChatListSnapshotStore(
                (ref.watch(messageStoreProvider) as SpyStore).inner
                    as DriftMessageStore,
              ),
              log,
            ),
          ),
        ],
      );
      c.listen(chatListSnapshotOwnerProvider, (_, _) {});
    });

    Future<void> signedIn() async {
      await c.read(sessionControllerProvider.future);
      await eventually(() => c.read(currentUserIdProvider) == 'ann');
    }

    void signOut() => (c.read(sessionControllerProvider.notifier) as _Session)
        .set(const SignedOut());

    test('plain: after sign-out no feed file remains', () async {
      await signedIn();
      await c.read(chatListSnapshotStoreProvider).save('ann', const [
        Conversation(id: 'c1', avatarPath: 'groups/c1.jpg'),
      ]);
      expect(feed().existsSync(), isTrue, reason: 'fixture: feed written');
      signOut();
      await eventually(() => log.contains('store.cleared'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(feed().existsSync(), isFalse);
      expect(feedPart().existsSync(), isFalse);
    });

    test('a save held at its database step on the old instance, finishing '
        'after the sign-out erase, leaves no feed file', () async {
      annFile = Completer<void>();
      await signedIn();
      final saving = c.read(chatListSnapshotStoreProvider).save('ann', const [
        Conversation(id: 'c1', avatarPath: 'groups/c1.jpg'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      signOut();
      await eventually(() => log.contains('store.cleared'));
      annFile!.complete();
      await saving;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(feed().existsSync(), isFalse, reason: 'feed re-written');
      expect(feedPart().existsSync(), isFalse, reason: 'feed .part left');
      expectNoFiles('database after the late save');
    });

    // Security re-gate 3: the REAL sign-out order (feed clear, delete rows,
    // store.clear) through the providers. A transaction held open on the same
    // store makes the save S wait inside the database (after it began), and
    // the delete-rows step queues behind S; S finishes before store.clear().
    for (final how in ['store follows the user', 'one store instance']) {
      test(
        're-gate 3 ($how): a save held inside the database at sign-out, finishing '
        'before store.clear, leaves no feed file once sign-out completes',
        () async {
          follow = how == 'store follows the user';
          await signedIn();
          final snap = c.read(chatListSnapshotStoreProvider);
          final inner =
              (c.read(messageStoreProvider) as SpyStore).inner
                  as DriftMessageStore;
          await snap.load('ann'); // the store is open
          final gate = Completer<void>();
          final entered = Completer<void>();
          final holding = inner.run<void>(
            null,
            (db) => db.transaction(() async {
              entered.complete();
              await gate.future;
            }),
          );
          await entered.future;
          final saving = snap.save('ann', const [
            Conversation(id: 'c1', avatarPath: 'groups/c1.jpg'),
          ]);
          unawaited(saving.then((_) => log.add('S.done')));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          signOut();
          await eventually(() => log.contains('snapshot.clear'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          gate.complete();
          await holding;
          await saving;
          await eventually(() => log.contains('store.cleared'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(
            feed().existsSync(),
            isFalse,
            reason: 'feed re-written after sign-out ($log)',
          );
          expect(feedPart().existsSync(), isFalse, reason: 'feed .part left');
          expectNoFiles('database after sign-out');
        },
      );
    }
  });
}
