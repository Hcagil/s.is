import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../crypto/application/key_directory_controller.dart';
import '../../crypto/domain/key_directory.dart';
import '../../crypto/domain/session_engine.dart';
import '../domain/reaction.dart';
import '../domain/reaction_envelope.dart';
import '../domain/reaction_opener.dart';
import '../domain/reaction_store.dart';

/// The on-phone store of opened locked reactions; null until main wires it.
final reactionStoreProvider = Provider<ReactionStore?>((_) => null);

/// The one step that opens locked reactions read from the server; main gives it to the reaction repository.
final reactionOpenerProvider = Provider<ReactionOpener>((ref) {
  return StoreReactionOpener(
    me: () => ref.read(currentUserIdProvider),
    engine: () => ref.read(sessionEngineProvider),
    store: () => ref.read(reactionStoreProvider),
    peerKey: (id) =>
        ref.read(keyDirectoryControllerProvider.notifier).identityVerified(id),
  );
});

/// Opens locked reactions one after the other (all peers on one queue), once each, and keeps the emoji in the on-phone store.
class StoreReactionOpener implements ReactionOpener {
  StoreReactionOpener({
    required this._me,
    required this._engine,
    required this._store,
    required this._peerKey,
  });

  final String? Function() _me;
  final SessionEngine? Function() _engine;
  final ReactionStore? Function() _store;
  final Future<Result<ClaimedKeys?>> Function(String userId) _peerKey;

  Future<void> _tail = Future<void>.value();
  final Map<String, String> _done = {};

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  Future<T> _serial<T>(Future<T> Function() job) {
    final r = _tail.then((_) => job());
    _tail = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  bool _locked(Reaction r) => r.ciphertext != null && r.emoji == null;

  @override
  Future<List<Reaction>> open(List<Reaction> rows) {
    if (rows.every((r) => !_locked(r))) {
      return Future.value(rows);
    }
    return _serial<List<Reaction>>(() async {
      final out = List<Reaction>.of(rows);
      // Oldest first, so a pre-key message makes its session before the normal ones behind it.
      final order =
          [
            for (var i = 0; i < rows.length; i++)
              if (_locked(rows[i])) i,
          ]..sort((a, b) {
            final c = (rows[a].updatedAt ?? _epoch).compareTo(
              rows[b].updatedAt ?? _epoch,
            );
            return c != 0 ? c : a.compareTo(b);
          });
      final keys = <String, Result<ClaimedKeys?>>{};
      for (final i in order) {
        try {
          out[i] = await _openOne(rows[i], keys);
        } catch (_) {
          out[i] = _shown(rows[i], null);
        }
      }
      return out;
    }).catchError((_) {
      return [for (final r in rows) _locked(r) ? _shown(r, null) : r];
    });
  }

  /// [r] without its ciphertext and with [emoji] (null: hidden, never text).
  Reaction _shown(Reaction r, String? emoji) => Reaction(
    messageId: r.messageId,
    userId: r.userId,
    emoji: emoji,
    updatedAt: r.updatedAt,
  );

  /// Opens one locked reaction [r]; never decrypts the same ciphertext twice (the stored copy, then the memory of this run, answer first). [keys] holds the peers' checked keys already looked up in this call.
  Future<Reaction> _openOne(
    Reaction r,
    Map<String, Result<ClaimedKeys?>> keys,
  ) async {
    final cipher = r.ciphertext!;
    final olmType = r.olmType;
    final hash = sha256.convert(utf8.encode(cipher)).toString();
    final me = _me();
    if (me == null || olmType == null) return _shown(r, null);
    final store = _store();
    final saved = await store?.emojiOf(r.messageId, r.userId, hash);
    if (saved != null) return _shown(r, saved);
    // The sender's own row is never decrypted: this phone's stored copy is the emoji.
    if (r.userId == me) return _shown(r, null);
    final slot = '${r.messageId}:${r.userId}:$hash';
    final done = _done[slot];
    if (done != null) return _shown(r, done);
    final engine = _engine();
    if (engine == null) return _shown(r, null);
    final looked = keys[r.userId] ??= await _peerKey(r.userId);
    final peerKey = switch (looked) {
      Ok(:final value) => value,
      Err() => null,
    };
    if (peerKey == null) return _shown(r, null);
    final result = await engine.decrypt(
      peerUserId: r.userId,
      peerIdentityKey: peerKey.identityKey,
      ciphertext: cipher,
      olmType: olmType,
    );
    switch (result) {
      case Ok(:final value):
        final emoji = decodeReactionEnvelope(
          value,
          messageId: r.messageId,
          userId: r.userId,
        );
        if (emoji == null) return _shown(r, null);
        // The ratchet moved, so this reaction can never be opened again: kept in memory even if the write fails.
        // shortcut: dropped wholesale at 1000, the store still answers.
        if (_done.length > 1000) _done.clear();
        _done[slot] = emoji;
        try {
          await store?.put(r.messageId, r.userId, hash, emoji);
        } catch (_) {}
        return _shown(r, emoji);
      case Err():
        return _shown(r, null);
    }
  }

  @override
  Future<void> rememberOwn(
    String messageId,
    String userId,
    String ciphertext,
    String emoji,
  ) async {
    final hash = sha256.convert(utf8.encode(ciphertext)).toString();
    try {
      await _store()?.put(messageId, userId, hash, emoji);
    } catch (_) {}
  }

  @override
  Future<Map<String, int>> ownUsage(String userId) async {
    try {
      return await _store()?.usageOf(userId) ?? const {};
    } catch (_) {
      return const {};
    }
  }
}
