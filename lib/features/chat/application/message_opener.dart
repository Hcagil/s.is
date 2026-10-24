import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../crypto/application/key_directory_controller.dart';
import '../../crypto/domain/key_directory.dart';
import '../../crypto/domain/security_code_store.dart';
import '../../crypto/domain/session_engine.dart';
import '../domain/encrypted_message_repository.dart';
import '../domain/message.dart';
import '../domain/message_envelope.dart';
import '../domain/message_opener.dart';
import '../domain/message_store.dart';
import 'chat_controllers.dart';
import 'open_queue.dart';
import 'security_code_controller.dart';

/// The one step that opens locked texts read from the server; main gives it to the chat repository.
final messageOpenerProvider = Provider<MessageOpener>((ref) {
  final opener = StoreMessageOpener(
    me: () => ref.read(currentUserIdProvider),
    engine: () => ref.read(sessionEngineProvider),
    store: () {
      try {
        return ref.read(messageStoreProvider);
      } catch (_) {
        return null;
      }
    },
    peerKey: (id) =>
        ref.read(keyDirectoryControllerProvider.notifier).identityVerified(id),
    memory: () => ref.read(cipherChatMemoryProvider),
    queue: ref.read(openQueueProvider),
  );
  ref.onDispose(opener.dispose);
  return opener;
});

CipherChatMemory? _noMemory() => null;

/// Opens locked texts one after the other (all peers on one queue), once each, and keeps the plaintext in the on-phone store.
class StoreMessageOpener implements MessageOpener {
  StoreMessageOpener({
    required this._me,
    required this._engine,
    required this._store,
    required this._peerKey,
    CipherChatMemory? Function()? memory,
    OpenQueue? queue,
  }) : _memory = memory ?? _noMemory,
       _queue = queue ?? OpenQueue();

  final String? Function() _me;
  final SessionEngine? Function() _engine;
  final MessageStore? Function() _store;
  final Future<Result<ClaimedKeys?>> Function(String userId) _peerKey;
  final CipherChatMemory? Function() _memory;
  final OpenQueue _queue;

  final _reopened = StreamController<Message>.broadcast();
  final Map<String, Message> _done = {};
  final Map<String, Message> _pending = {};

  @override
  Stream<Message> get reopened => _reopened.stream;

  // shortcut: ids stay for the opener's life (a hidden message never comes back); bounded by the user's own hides.
  final Set<String> _forgotten = {};

  @override
  void forget(String id) {
    _forgotten.add(id);
    _pending.remove(id);
  }

  /// Closes the [reopened] stream.
  void dispose() {
    unawaited(_reopened.close());
  }

  Future<T> _serial<T>(Future<T> Function() job) => _queue.run(job);

  bool _locked(Message m) =>
      m.ciphertext != null && m.olmType != null && m.deletion == null;

  @override
  Future<List<Message>> open(List<Message> rows) {
    final memory = _memory();
    if (rows.every((m) => !_locked(m)) &&
        (memory == null || !rows.any(_plainSuspect))) {
      return Future.value(rows);
    }
    return _serial<List<Message>>(() async {
      final out = List<Message>.of(rows);
      await _markHeld(rows, memory);
      final keys = <String, Result<ClaimedKeys?>>{};
      // Oldest first, so a pre-key message makes its session before the normal ones behind it.
      final order =
          [
            for (var i = 0; i < rows.length; i++)
              if (_locked(rows[i])) i,
          ]..sort((a, b) {
            final c = rows[a].createdAt.compareTo(rows[b].createdAt);
            return c != 0 ? c : a.compareTo(b);
          });
      final inBatch = {for (final i in order) rows[i].id};
      final fresh = <String>{};
      for (final i in order) {
        try {
          out[i] = await _openOne(rows[i], keys);
        } catch (_) {
          out[i] = rows[i].withPlain(lockedBodyPlaceholder, null);
        }
        if (rows[i].olmType == 0 && !isLockedPlaceholder(out[i].body)) {
          fresh.add(rows[i].senderId);
        }
      }
      // A pre-key message opened: rows that waited for that peer's session may open now.
      for (final peer in fresh) {
        try {
          await _retryPending(peer, inBatch);
        } catch (_) {}
      }
      return _guardPlain(out, rows, memory);
    }).catchError((_) {
      return [
        for (final m in rows)
          _locked(m) ? m.withPlain(lockedBodyPlaceholder, null) : m,
      ];
    });
  }

  /// A plain text from someone else: no ciphertext, no attachment, not deleted, and not a kind the server allows plain in an encrypted chat (poll, contact, location, sticker, album card, admin note).
  bool _plainSuspect(Message m) =>
      m.ciphertext == null &&
      m.olmType == null &&
      m.deletion == null &&
      !m.hasAttachment &&
      !m.poll &&
      !m.contact &&
      m.location == null &&
      !m.albumCard &&
      m.stickerId == null &&
      m.adminMsg == null &&
      m.body.isNotEmpty &&
      !isLockedPlaceholder(m.body) &&
      m.senderId != _me();

  /// Remembers per chat when it first held a locked text.
  Future<void> _markHeld(List<Message> rows, CipherChatMemory? memory) async {
    if (memory == null) return;
    for (final m in rows) {
      if (!_locked(m)) continue;
      try {
        await memory.markHeld(m.conversationId, m.createdAt);
      } catch (_) {}
    }
  }

  /// A plain text created after its chat first held a locked text is not trusted: it gets the locked look (a server could slip a plain text under a person's name).
  Future<List<Message>> _guardPlain(
    List<Message> out,
    List<Message> rows,
    CipherChatMemory? memory,
  ) async {
    if (memory == null) return out;
    final since = <String, DateTime?>{};
    for (var i = 0; i < rows.length; i++) {
      final m = rows[i];
      if (!_plainSuspect(m)) continue;
      if (!since.containsKey(m.conversationId)) {
        try {
          since[m.conversationId] = await memory.heldSince(m.conversationId);
        } catch (_) {
          since[m.conversationId] = null;
        }
      }
      final first = since[m.conversationId];
      if (first != null && m.createdAt.isAfter(first)) {
        out[i] = m.withPlain(lockedBodyPlaceholder, null);
      }
    }
    return out;
  }

  /// Opens one locked row [m]; never decrypts the same ciphertext twice (the memory of this run, then the stored copy, answer first). [keys] holds the peers' checked keys already looked up in this call.
  Future<Message> _openOne(
    Message m,
    Map<String, Result<ClaimedKeys?>> keys,
  ) async {
    final cipher = m.ciphertext!;
    final hash = sha256.convert(utf8.encode(cipher)).toString();
    final slot = '${m.id}:$hash';
    final store = _store();
    Message? stored;
    if (store != null) {
      final near = await store.around(m.conversationId, m.id, each: 0);
      stored = near.where((s) => s.id == m.id).firstOrNull;
    }
    // A deleted row stays deleted: never decrypted, never written over.
    if (stored?.deletion != null) return stored!;
    // The server may not move a stored text to another sender: the stored row is shown as it is, never relabelled.
    if (stored != null && stored.senderId != m.senderId) return stored;
    final have = stored != null && !isLockedPlaceholder(stored.body)
        ? stored
        : null;
    final unreadable = m.withPlain(lockedBodyPlaceholder, null);
    // A stored plaintext is never replaced by a failure (an unreadable edit keeps the old text).
    final fallback = have == null
        ? unreadable
        : m.withPlain(have.body, have.linkPreview, sealed: have.sealed);
    final me = _me();
    if (me == null) return fallback;
    // The sender's own row is never decrypted: this phone's stored copy is the text.
    if (m.senderId == me) return fallback;
    final done = _done[slot];
    if (done != null) {
      return isLockedPlaceholder(done.body)
          ? fallback
          : m.withPlain(done.body, done.linkPreview, sealed: hash);
    }
    if (have != null && have.sealed == hash) {
      return m.withPlain(have.body, have.linkPreview, sealed: hash);
    }
    final engine = _engine();
    if (engine == null) return fallback;
    final looked = keys[m.senderId] ??= await _peerKey(m.senderId);
    final peerKey = switch (looked) {
      Ok(:final value) => value,
      Err() => null,
    };
    if (peerKey == null) {
      _wait(m);
      return fallback;
    }
    final result = await engine.decrypt(
      peerUserId: m.senderId,
      peerIdentityKey: peerKey.identityKey,
      ciphertext: cipher,
      olmType: m.olmType!,
    );
    switch (result) {
      case Ok(:final value):
        final env = decodeEnvelope(value, m.id);
        if (env == null) {
          _remember(slot, unreadable);
          return fallback;
        }
        // Hidden while this decrypt ran: the text is dropped, never stored or shown.
        if (_forgotten.contains(m.id)) return fallback;
        final plain = m.withPlain(env.text, env.card, sealed: hash);
        _pending.remove(m.id);
        _remember(slot, plain);
        // The ratchet moved, so this message can never be opened again: saved before it is shown, kept in memory even if the write fails.
        try {
          await store?.upsertAll([plain]);
          // A deletion that landed while decrypting wins over the text.
          final near = await store?.around(m.conversationId, m.id, each: 0);
          final now = near?.where((s) => s.id == m.id).firstOrNull;
          if (now?.deletion != null) return now!;
        } catch (_) {}
        return plain;
      case Err(failure: SessionPendingFailure()):
        _wait(m);
        return fallback;
      case Err(failure: UnreadableMessageFailure()):
        _remember(slot, unreadable);
        return fallback;
      case Err():
        return fallback;
    }
  }

  void _remember(String slot, Message result) {
    // shortcut: dropped wholesale at 1000, the store still answers
    if (_done.length > 1000) _done.clear();
    _done[slot] = result;
  }

  void _wait(Message m) {
    if (!_pending.containsKey(m.id) && _pending.length >= 200) {
      _pending.remove(_pending.keys.first);
    }
    _pending[m.id] = m;
  }

  /// Opens the rows of [peer] that waited for a session (except [skip], the rows of the call in progress) and sends each one that opened on [reopened].
  Future<void> _retryPending(String peer, Set<String> skip) async {
    final waiting = [
      for (final m in _pending.values)
        if (m.senderId == peer && !skip.contains(m.id)) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final keys = <String, Result<ClaimedKeys?>>{};
    for (final m in waiting) {
      final opened = await _openOne(m, keys);
      if (opened.deletion != null) {
        _pending.remove(m.id);
        continue;
      }
      if (!isLockedPlaceholder(opened.body)) {
        _pending.remove(m.id);
        if (!_reopened.isClosed && !_forgotten.contains(m.id)) {
          _reopened.add(opened);
        }
      }
    }
  }
}
