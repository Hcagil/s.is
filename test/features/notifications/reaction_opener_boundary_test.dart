// reactionOpener (main-isolate opener of a private reaction push) against the
// REAL peek store: two real Olm phones, a real encrypted store file, the real
// peekReaction. Only the platform side is faked: the secure-storage channel
// (store key, pickle key) and the path_provider channel (where the file is).
// Written from the contract, never from the implementation.
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/reaction_envelope.dart';
import 'package:sis/features/notifications/data/reaction_opener.dart';
import 'package:sis/features/notifications/domain/reaction_push.dart';

import '../chat/data/store/store_harness.dart' show msg;
import '../crypto/data/olm_peek_reaction_test.dart'
    show Phone, aliceId, bobId, conv, mine, ok, thumb;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Phone alice;
  late Phone bob;
  const storeKeyName = 'sis.store.key';
  const pickleKeyName = 'sis.olm.pickle.key';

  String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  setUp(() async {
    alice = await Phone.make(aliceId);
    bob = await Phone.make(bobId);
    await DriftChatListSnapshotStore(alice.store).save(aliceId, const [
      Conversation(
        id: conv,
        other: Member(userId: bobId, displayName: 'Bob'),
      ),
    ]);
    // The harness already replaced the secure-storage platform with an
    // in-memory one; the phone's two keys are the only things faked.
    FlutterSecureStorage.setMockInitialValues({
      storeKeyName: alice.keyHex,
      pickleKeyName: hex(alice.pk),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? alice.h.dir.path
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );
  });

  /// Alice and Bob have talked both ways; Bob's reaction is a type 1 message.
  Future<ReactionPush> bobReacts() async {
    ok(await alice.engine.createOutbound(bobId, bob.keys()));
    final first = ok(
      await alice.engine.encrypt(
        bobId,
        encodeEnvelope(id: 'w1', text: 'first'),
        peerIdentityKey: bob.identityKey,
      ),
    );
    ok(
      await bob.engine.decrypt(
        peerUserId: aliceId,
        peerIdentityKey: alice.identityKey,
        ciphertext: first.ciphertext,
        olmType: first.olmType,
      ),
    );
    await alice.store.upsertAll([
      msg(mine, conv: conv, sender: aliceId, body: 'See you at 6'),
    ]);
    final l = ok(
      await bob.engine.encrypt(
        aliceId,
        encodeReactionEnvelope(messageId: mine, userId: bobId, emoji: thumb),
        peerIdentityKey: alice.identityKey,
      ),
    );
    await alice.store.close();
    return (
      userId: aliceId,
      conversationId: conv,
      messageId: mine,
      reactorId: bobId,
      emoji: null,
      quote: null,
      quoteKind: null,
      ciphertext: l.ciphertext,
      olmType: l.olmType,
    );
  }

  test(
    'opens a real private reaction: emoji and quote from the store',
    () async {
      final p = await bobReacts();
      final got = await reactionOpener(null)(p);
      expect(got?.emoji, thumb);
      expect(got?.quote, 'See you at 6');
    },
  );

  test('no store key on the phone: null, nothing created', () async {
    final p = await bobReacts();
    FlutterSecureStorage.setMockInitialValues({});
    expect(await reactionOpener(null)(p), isNull);
    expect(
      await const FlutterSecureStorage().readAll(),
      isEmpty,
      reason: 'a notification never makes a key',
    );
  });

  test('no pickle key: null', () async {
    final p = await bobReacts();
    FlutterSecureStorage.setMockInitialValues({storeKeyName: alice.keyHex});
    expect(await reactionOpener(null)(p), isNull);
  });

  test('a push without ciphertext: null', () async {
    final p = await bobReacts();
    final plain = (
      userId: p.userId,
      conversationId: p.conversationId,
      messageId: p.messageId,
      reactorId: p.reactorId,
      emoji: 'x',
      quote: null,
      quoteKind: null,
      ciphertext: null,
      olmType: null,
    );
    expect(await reactionOpener(null)(plain), isNull);
  });

  test('a wrong store key: null, no throw', () async {
    final p = await bobReacts();
    FlutterSecureStorage.setMockInitialValues({
      storeKeyName: '0f' * 32,
      pickleKeyName: hex(alice.pk),
    });
    expect(await reactionOpener(null)(p), isNull);
  });

  test(
    'a locked store does not freeze the main isolate (peek runs off it)',
    () async {
      final p = await bobReacts();
      // Another connection holds the whole store, as a running app can.
      final lock = sqlite3.open(alice.h.file.path)
        ..execute("PRAGMA key = \"x'${alice.keyHex}'\";")
        ..execute('PRAGMA locking_mode = EXCLUSIVE;')
        ..execute('BEGIN EXCLUSIVE;');
      addTearDown(lock.close);
      final clock = Stopwatch()..start();
      var last = 0;
      var worstGapMs = 0;
      var ticks = 0;
      final ticker = Timer.periodic(const Duration(milliseconds: 20), (_) {
        ticks++;
        final now = clock.elapsedMilliseconds;
        if (now - last > worstGapMs) worstGapMs = now - last;
        last = now;
      });
      final got = await reactionOpener(null)(p);
      ticker.cancel();
      expect(got, isNull, reason: 'a locked store gives no text');
      expect(
        clock.elapsedMilliseconds,
        lessThan(3000),
        reason: 'the caller caps at 3 s; the opener must answer sooner',
      );
      expect(ticks, greaterThan(10), reason: 'main timers kept firing');
      expect(
        worstGapMs,
        lessThan(300),
        reason: 'main isolate was blocked for ${worstGapMs}ms',
      );
    },
  );

  test('a failure while reading the keys surfaces as a thrown error', () async {
    final p = await bobReacts();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => throw PlatformException(code: 'boom'),
        );
    await expectLater(reactionOpener(null)(p), throwsA(anything));
  });

  test('no store key: null, and the store file is never looked for', () async {
    final p = await bobReacts();
    FlutterSecureStorage.setMockInitialValues({pickleKeyName: hex(alice.pk)});
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              asked++;
            }
            return alice.h.dir.path;
          },
        );
    expect(await reactionOpener(null)(p), isNull);
    expect(
      asked,
      0,
      reason: 'a missing key must stop before the store is opened',
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );
  });

  test('no pickle key: null, and the store file is never looked for', () async {
    final p = await bobReacts();
    FlutterSecureStorage.setMockInitialValues({storeKeyName: alice.keyHex});
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              asked++;
            }
            return alice.h.dir.path;
          },
        );
    expect(await reactionOpener(null)(p), isNull);
    expect(
      asked,
      0,
      reason: 'a missing key must stop before the store is opened',
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );
  });
}
