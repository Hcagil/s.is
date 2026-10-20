// Fakes for the receive path (StoreMessageOpener), written by qa from the
// SessionEngine / MessageStore interfaces, never from the implementation.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';

/// One decrypt call as the engine saw it.
typedef DecryptCall = ({
  String peer,
  String identityKey,
  String ciphertext,
  int olmType,
});

/// A SessionEngine whose decrypt answers from [answer] (by ciphertext) after
/// [latency]. Like the real engine it answers each ciphertext once only: a
/// second decrypt of an already opened ciphertext is Unreadable (Olm cannot
/// open the same message twice). Anything else than decrypt is a test error.
class ScriptEngine implements SessionEngine {
  ScriptEngine({this.latency = const Duration(milliseconds: 2)});

  final Duration latency;
  final calls = <DecryptCall>[];
  final Map<String, Result<String> Function()> answer = {};
  final Set<String> _opened = {};

  /// Throws instead of answering for these ciphertexts.
  final Set<String> throwFor = {};

  /// Runs inside decrypt, after the latency (something else happening on
  /// the phone while the engine works).
  Future<void> Function(String ciphertext)? during;

  @override
  Future<Result<String>> decrypt({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) async {
    calls.add((
      peer: peerUserId,
      identityKey: peerIdentityKey,
      ciphertext: ciphertext,
      olmType: olmType,
    ));
    await Future<void>.delayed(latency);
    await during?.call(ciphertext);
    if (throwFor.contains(ciphertext)) throw StateError('engine crashed');
    if (_opened.contains(ciphertext)) {
      return const Err(UnreadableMessageFailure());
    }
    final r =
        (answer[ciphertext] ?? () => const Err(UnreadableMessageFailure()))();
    if (r is Ok<String>) _opened.add(ciphertext);
    return r;
  }

  List<String> get decrypted => [for (final c in calls) c.ciphertext];

  @override
  Future<bool> hasSession(String peerUserId) =>
      throw UnimplementedError('hasSession');
  @override
  Future<Result<String>> createOutbound(String peerUserId, ClaimedKeys keys) =>
      throw UnimplementedError('createOutbound');
  @override
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    required String peerIdentityKey,
    PlaintextSave? save,
    QueueTarget? queue,
  }) => throw UnimplementedError('encrypt');
  @override
  Future<Result<String>> createInbound({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) => throw UnimplementedError('createInbound');
}

/// The directory identity key the fake peerKey hands out for [userId].
String identityOf(String userId) => 'IK-$userId';

ClaimedKeys keysOf(String userId) => ClaimedKeys(
  identityKey: identityOf(userId),
  signingKey: 'SK-$userId',
  deviceSignature: 'sig-$userId',
  oneTimeKey: '',
  isFallback: false,
);

/// peerKey as KeyDirectoryController.identityVerified answers it; [answer]
/// overrides per user (Err offline, Ok(null) no phone).
class FakePeerKeys {
  final calls = <String>[];
  final Map<String, Result<ClaimedKeys?>> answer = {};

  Future<Result<ClaimedKeys?>> call(String userId) async {
    calls.add(userId);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return answer[userId] ?? Ok(keysOf(userId));
  }
}

/// The two hashes "sha256 hex of the ciphertext" can mean (of the base64
/// text, or of the Olm bytes it encodes).
Set<String> sealsOf(String ciphertext) => {
  sha256.convert(utf8.encode(ciphertext)).toString(),
  sha256.convert(base64Decode(ciphertext)).toString(),
};

/// A base64 ciphertext unique to [tag].
String ct(String tag) => base64Encode(utf8.encode('olm:$tag'));

/// A MessageStore over a real one whose writes take [writeDelay] (a slow
/// phone disk); reads go straight through. Counts upserted ids.
class SlowStore implements MessageStore {
  SlowStore(this.real, {this.writeDelay = Duration.zero});

  final MessageStore real;
  Duration writeDelay;
  final upserted = <String>[];

  /// Writes are skipped silently (the store contract for a failed write).
  bool dropWrites = false;

  /// Writes throw (a store that breaks its contract).
  bool throwWrites = false;

  Future<bool> _write() async {
    await Future<void>.delayed(writeDelay);
    if (throwWrites) throw StateError('disk full');
    return !dropWrites;
  }

  @override
  Future<void> upsertAll(List<Message> messages) async {
    if (!await _write()) return;
    upserted.addAll(messages.map((m) => m.id));
    await real.upsertAll(messages);
  }

  @override
  Future<void> reconcilePage(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) async {
    if (!await _write()) return;
    upserted.addAll(page.map((m) => m.id));
    await real.reconcilePage(conversationId, page, reachedStart: reachedStart);
  }

  @override
  Future<List<Message>> newest(String conversationId, {int limit = 50}) =>
      real.newest(conversationId, limit: limit);
  @override
  Future<List<Message>> older(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) => real.older(conversationId, before, limit: limit);
  @override
  Future<List<Message>> around(
    String conversationId,
    String messageId, {
    int each = 50,
  }) => real.around(conversationId, messageId, each: each);
  @override
  Future<void> extendOlder(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) => real.extendOlder(conversationId, page, reachedStart: reachedStart);
  @override
  Future<void> remove(String messageId) => real.remove(messageId);
  @override
  Future<void> deleteConversation(String conversationId) =>
      real.deleteConversation(conversationId);
  @override
  Future<List<Message>> search(
    String query, {
    String? conversationId,
    int limit = 100,
  }) => real.search(query, conversationId: conversationId, limit: limit);
  @override
  Future<StoredSync?> syncState(String conversationId) =>
      real.syncState(conversationId);
  @override
  Future<ChangeCursor?> cursor() => real.cursor();
  @override
  Future<void> saveCursor(ChangeCursor cursor) => real.saveCursor(cursor);
  @override
  Future<Set<String>> conversationIds() => real.conversationIds();
  @override
  Future<void> clear() => real.clear();
}
