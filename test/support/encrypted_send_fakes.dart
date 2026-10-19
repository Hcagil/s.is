// Fakes for the encrypted send path, written from the interfaces in
// lib/features/crypto/domain/session_engine.dart and
// lib/features/chat/domain/encrypted_message_repository.dart, never from the
// implementation. They behave like the real parts where it matters:
// - encrypt only works on a session made for the peer's CURRENT identity key
//   (else SessionPendingFailure), and writes the ciphertext onto the queue
//   row in the same step, only when that row exists;
// - every ciphertext is new (Olm never repeats one);
// - the server stores a locked row with the placeholder body, refuses an edit
//   of a row that is not a locked row of ours, and answers after a hop;
// - any call can answer with an error instead.
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';

import 'memory_send_queue_store.dart';

typedef EncryptCall = ({
  String peer,
  String plaintext,
  String peerIdentityKey,
  QueueTarget? queue,
});

class FakeSessionEngine implements SessionEngine {
  FakeSessionEngine({this.queue});

  /// Where a QueueTarget's ciphertext is written (the send_queue table).
  final MemorySendQueueStore? queue;

  /// peer -> the identity keys a session is stored for.
  final sessions = <String, Set<String>>{};
  final encrypts = <EncryptCall>[];
  final outbound = <(String, ClaimedKeys)>[];

  /// Forced answers for the next encrypts / createOutbounds, in order.
  final encryptAnswers = <Result<LockedText>>[];
  final outboundAnswers = <Result<String>>[];
  int _seq = 0;

  @override
  Future<bool> hasSession(String peerUserId) async =>
      sessions[peerUserId]?.isNotEmpty ?? false;

  @override
  Future<Result<String>> createOutbound(
    String peerUserId,
    ClaimedKeys keys,
  ) async {
    outbound.add((peerUserId, keys));
    await Future<void>.value();
    if (outboundAnswers.isNotEmpty) return outboundAnswers.removeAt(0);
    // Sessions for another key of that peer are dropped.
    sessions[peerUserId] = {keys.identityKey};
    return Ok('session-$peerUserId');
  }

  @override
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    required String peerIdentityKey,
    PlaintextSave? save,
    QueueTarget? queue,
  }) async {
    encrypts.add((
      peer: peerUserId,
      plaintext: plaintext,
      peerIdentityKey: peerIdentityKey,
      queue: queue,
    ));
    await Future<void>.value();
    if (encryptAnswers.isNotEmpty) {
      final forced = encryptAnswers.removeAt(0);
      if (forced case Ok(:final value) when queue != null) {
        this.queue?.write(
          queue.userId,
          queue.queueId,
          value.ciphertext,
          value.olmType,
        );
      }
      return forced;
    }
    if (!(sessions[peerUserId]?.contains(peerIdentityKey) ?? false)) {
      return const Err(SessionPendingFailure());
    }
    final n = ++_seq;
    final locked = LockedText(
      ciphertext: 'Q1QtJHtuXQ$n',
      olmType: n == 1 ? 0 : 1,
      sessionId: 'session-$peerUserId',
    );
    if (queue != null) {
      this.queue?.write(
        queue.userId,
        queue.queueId,
        locked.ciphertext,
        locked.olmType,
      );
    }
    return Ok(locked);
  }

  @override
  Future<Result<String>> createInbound({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) => throw UnimplementedError('not on the send path');

  @override
  Future<Result<String>> decrypt({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) => throw UnimplementedError('not on the send path');
}

typedef LockedSend = ({
  String id,
  String conversationId,
  String ciphertext,
  int olmType,
  String? replyTo,
  bool forwarded,
});

class FakeEncryptedMessageRepository implements EncryptedMessageRepository {
  FakeEncryptedMessageRepository({required this.self});

  /// The signed-in member: the server writes the sender from the session.
  final String self;
  final sends = <LockedSend>[];
  final edits = <({String id, String ciphertext, int olmType})>[];

  /// Forced answers for the next sends / edits, in order.
  final sendAnswers = <Result<Message>>[];
  final editAnswers = <Result<Message>>[];

  /// The locked rows the server holds, by id.
  final rows = <String, Message>{};

  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String ciphertext,
    required int olmType,
    String? replyTo,
    bool forwarded = false,
  }) async {
    sends.add((
      id: id,
      conversationId: conversationId,
      ciphertext: ciphertext,
      olmType: olmType,
      replyTo: replyTo,
      forwarded: forwarded,
    ));
    await Future<void>.value();
    if (sendAnswers.isNotEmpty) return sendAnswers.removeAt(0);
    final row = Message(
      id: id,
      conversationId: conversationId,
      senderId: self,
      body: lockedBodyPlaceholder,
      createdAt: DateTime.now(),
      replyTo: replyTo,
      forwarded: forwarded,
    );
    rows[id] = row;
    return Ok(row);
  }

  @override
  Future<Result<Message>> edit({
    required String id,
    required String ciphertext,
    required int olmType,
  }) async {
    edits.add((id: id, ciphertext: ciphertext, olmType: olmType));
    await Future<void>.value();
    if (editAnswers.isNotEmpty) return editAnswers.removeAt(0);
    final row = rows[id];
    // edit_message_encrypted refuses anything but our own locked row.
    if (row == null || row.senderId != self) return const Err(DeniedFailure());
    final edited = Message(
      id: row.id,
      conversationId: row.conversationId,
      senderId: row.senderId,
      body: lockedBodyPlaceholder,
      createdAt: row.createdAt,
      replyTo: row.replyTo,
      editedAt: DateTime.now(),
    );
    rows[id] = edited;
    return Ok(edited);
  }
}
