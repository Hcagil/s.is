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
}
