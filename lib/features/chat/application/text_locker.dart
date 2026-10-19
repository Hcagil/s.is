import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../crypto/application/key_directory_controller.dart';
import '../../crypto/domain/key_directory.dart';
import '../../crypto/domain/session_engine.dart';
import '../domain/conversation.dart';
import '../domain/encrypted_message_repository.dart';
import '../domain/link_preview.dart';
import '../domain/message_envelope.dart';
import '../domain/send_queue_store.dart';
import 'chat_controllers.dart';

/// The server side of locked texts; null until main wires it (tests, unwired builds): texts then go plain.
final encryptedMessageRepositoryProvider =
    Provider<EncryptedMessageRepository?>((_) => null);

/// The saved ciphertext of queued sends; null until main wires it.
final queuedCiphertextsProvider = Provider<QueuedCiphertexts?>((_) => null);

/// Decides whether a text is locked and locks it. See [TextLocker.lock].
final textLockerProvider = Provider<TextLocker>(TextLocker.new);

/// Decides whether a text leaves the phone locked, and locks it.
class TextLocker {
  TextLocker(this._ref);

  final Ref _ref;

  /// The one other member of a direct human chat [conversationId]; Ok(null) for a group, the system chat, an admin chat; Err when the chat is not in the list, even after one re-read (a chat just started may not be in it yet).
  Future<Result<String?>> _peerOf(String conversationId) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt == 1) {
        await _ref.read(conversationListProvider.notifier).reloadQuietly();
      }
      final List<Conversation> list;
      try {
        list = await _ref.read(conversationListProvider.future);
      } catch (_) {
        return const Err(DeniedFailure());
      }
      for (final c in list) {
        if (c.id != conversationId) continue;
        if (c.title != null || c.isSystem || c.isAdminChat) {
          return const Ok(null);
        }
        final other = c.other;
        return other == null ? const Err(DeniedFailure()) : Ok(other.userId);
      }
    }
    return const Err(DeniedFailure());
  }

  /// Ok(null): send the text plain (a group, system or admin chat, a bot or a person with no published keys, or locking is not wired). Ok(locked): send this ciphertext (the envelope of [messageId], [text] and [card] locked for the other member). Err: do NOT send at all (never fall back to plain): keys that fail their signature check, no secure session, a store error, offline.
  /// [queued] true: the send_queue row [messageId] of the member exists; a ciphertext already saved on it by an earlier attempt is returned as it is (a retry sends the same bytes) and a new one is saved on the row in the same transaction as the session. false (a forward): nothing is stored.
  Future<Result<QueuedCiphertext?>> lock({
    required String conversationId,
    required String messageId,
    required String text,
    LinkPreview? card,
    bool queued = false,
  }) async {
    final engine = _ref.read(sessionEngineProvider);
    if (engine == null) return const Ok(null);
    final me = _ref.read(currentUserIdProvider);
    if (me == null) return const Err(DeniedFailure());
    final peerResult = await _peerOf(conversationId);
    final String peer;
    switch (peerResult) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: null):
        return const Ok(null);
      case Ok(:final value?):
        peer = value;
    }
    if (queued) {
      final saved = await _ref
          .read(queuedCiphertextsProvider)
          ?.ciphertextOf(me, messageId);
      if (saved != null) return Ok(saved);
    }
    final keys = _ref.read(keyDirectoryControllerProvider.notifier);
    final identity = await keys.identityVerified(peer);
    final ClaimedKeys known;
    switch (identity) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: null):
        return const Ok(null);
      case Ok(:final value?):
        known = value;
    }
    final envelope = encodeEnvelope(id: messageId, text: text, card: card);
    final target = queued ? QueueTarget(me, messageId) : null;
    var locked = await engine.encrypt(
      peer,
      envelope,
      peerIdentityKey: known.identityKey,
      queue: target,
    );
    if (locked case Err(failure: SessionPendingFailure())) {
      // No session for this key yet: claim a one-time key once and open one.
      final claimed = await keys.claimVerified(peer);
      final ClaimedKeys fresh;
      switch (claimed) {
        case Err(:final failure):
          return Err(failure);
        case Ok(value: null):
          return const Err(SessionPendingFailure());
        case Ok(:final value?):
          fresh = value;
      }
      if (fresh.identityKey != known.identityKey) {
        return const Err(DeviceKeysFailure());
      }
      final opened = await engine.createOutbound(peer, fresh);
      if (opened case Err(:final failure)) return Err(failure);
      locked = await engine.encrypt(
        peer,
        envelope,
        peerIdentityKey: known.identityKey,
        queue: target,
      );
    }
    return switch (locked) {
      Ok(:final value) => Ok(QueuedCiphertext(value.ciphertext, value.olmType)),
      Err(:final failure) => Err(failure),
    };
  }
}
