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
import 'peer_key_cache.dart';
import 'security_code_controller.dart';

/// The locked rows this phone is still trying to open (waiting for a session). A locked row not in this list could not be opened for good; the screens say "opening" or "could not be opened" by it.
final openingMessagesProvider =
    NotifierProvider<OpeningMessages, List<Message>>(OpeningMessages.new);

class OpeningMessages extends Notifier<List<Message>> {
  @override
  List<Message> build() => const [];

  void set(List<Message> rows) => state = rows;
}

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
    cache: ref.read(peerKeyCacheProvider),
    onOpening: (rows) => ref.read(openingMessagesProvider.notifier).set(rows),
  );
  ref.onDispose(opener.dispose);
  ref.listen(currentUserIdProvider, (_, _) => opener.reset());
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
    this._cache,
    this._onOpening,
  }) : _memory = memory ?? _noMemory,
       _queue = queue ?? OpenQueue();

  final String? Function() _me;
  final SessionEngine? Function() _engine;
  final MessageStore? Function() _store;
  final Future<Result<ClaimedKeys?>> Function(String userId) _peerKey;
  final CipherChatMemory? Function() _memory;
  final OpenQueue _queue;
  final PeerKeyCache? _cache;
  final void Function(List<Message>)? _onOpening;

  final _reopened = StreamController<Message>.broadcast();
  final Map<String, Message> _done = {};
  final Map<String, Message> _pending = {};
  Timer? _timer;
  int _tries = 0;
  bool _disposed = false;
  static const _retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  @override
  Stream<Message> get reopened => _reopened.stream;

  // shortcut: ids stay for the opener's life (a hidden message never comes back); bounded by the user's own hides.
  final Set<String> _forgotten = {};

  @override
  void forget(String id) {
    _forgotten.add(id);
    _pending.remove(id);
    _publish();
  }

  /// Tells the screens which rows are still being opened.
  void _publish() {
    if (_disposed) return;
    _onOpening?.call(List.of(_pending.values));
  }

  /// Closes the [reopened] stream.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_reopened.close());
  }

  /// Forgets everything kept for the previous member (waiting rows, opened copies, hidden ids, the retry timer).
  void reset() {
    _timer?.cancel();
    _timer = null;
    _tries = 0;
    _pending.clear();
    _publish();
    _done.clear();
    _forgotten.clear();
    _cache?.clear();
  }

  Future<T> _serial<T>(Future<T> Function() job) => _queue.run(job);

  bool _locked(Message m) =>
      m.ciphertext != null && m.olmType != null && m.deletion == null;

  /// Only one of ciphertext / olmType is set: a forged row, never real text.
  bool _half(Message m) =>
      (m.ciphertext == null) != (m.olmType == null) && m.deletion == null;

  @override
  Future<List<Message>> open(List<Message> rows, {bool fresh = false}) {
    final memory = _memory();
    if (rows.every((m) => !_locked(m) && !_half(m)) &&
        (memory == null || !rows.any(_plainSuspect))) {
      return Future.value(rows);
    }
    return _serial<List<Message>>(() async {
      // A real open restarts the backoff: the old (maybe 5-minute) timer is replaced by a 5 s one.
      _timer?.cancel();
      _timer = null;
      _tries = 0;
      if (_pending.isNotEmpty) _schedule();
      final out = List<Message>.of(rows);
      for (var i = 0; i < rows.length; i++) {
        if (_half(rows[i])) {
          out[i] = rows[i].withPlain(lockedBodyPlaceholder, null);
        }
      }
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
      final preKeyPeers = <String>{};
      for (final i in order) {
        // A pre-key message may drop the peer's old sessions: rows of that peer still waiting open with them first.
        if (rows[i].olmType == 0) {
          try {
            await _retryPending(rows[i].senderId, inBatch);
          } catch (_) {}
        }
        try {
          out[i] = await _openOne(rows[i], keys);
        } catch (_) {
          out[i] = rows[i].withPlain(lockedBodyPlaceholder, null);
        }
        if (rows[i].olmType == 0 && !isLockedPlaceholder(out[i].body)) {
          preKeyPeers.add(rows[i].senderId);
        }
      }
      // A pre-key message opened: rows that waited for that peer's session may open now.
      for (final peer in preKeyPeers) {
        try {
          await _retryPending(peer, inBatch);
        } catch (_) {}
      }
      return _guardPlain(out, rows, memory, fresh);
    }).catchError((_) {
      return [
        for (final m in rows)
          _locked(m) || _half(m) ? m.withPlain(lockedBodyPlaceholder, null) : m,
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
    bool fresh,
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
      // shortcut: history older than what this phone holds trusts backdated plain rows (a fresh install holds nothing); closing it needs the sender to sign the lock fact (Private Chats step 6)
      // If the server leaves a chat out of the list, deleteConversation wipes its rows and sync_state; the held mark survives, so only rows backdated before the first locked message pass, the same limit as a fresh install.
      // A plain text the server refuses after the first locked text: one that is new to the phone, sits in the range it holds, or was shut before is not trusted by its date.
      if (first != null &&
          (m.createdAt.isAfter(first) || await _doubted(m, fresh))) {
        out[i] = m.withPlain(lockedBodyPlaceholder, null);
      }
    }
    return out;
  }

  /// True when a plain text [m] should be doubted for a reason other than its date: its stored copy is the locked placeholder (the guard shut it before); or it is not stored with readable text and it just arrived ([fresh]) or lies inside the range of the chat this phone already holds. Store missing or failing: false (the date rule alone decides). A fresh install has no range, so history older than what it holds stays on the date rule.
  Future<bool> _doubted(Message m, bool fresh) async {
    final store = _store();
    if (store == null) return false;
    try {
      final near = await store.around(m.conversationId, m.id, each: 0);
      final stored = near.where((s) => s.id == m.id).firstOrNull;
      if (stored != null) return isLockedPlaceholder(stored.body);
      if (fresh) return true;
      final from = (await store.syncState(m.conversationId))?.contiguousFrom;
      return from != null && !m.createdAt.isBefore(from);
    } catch (_) {
      return false;
    }
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
    final cache = _cache;
    // A pre-key message can create a session (and drop the old ones), so it always asks the server; a normal message may use the kept keys.
    final looked = cache == null
        ? (keys[m.senderId] ??= await _peerKey(m.senderId))
        : m.olmType == 0
        ? (keys[m.senderId] = await cache.get(m.senderId, fresh: true))
        : (keys[m.senderId] ??= await cache.get(m.senderId));
    // Disposed while the key lookup ran: never decrypt (it would use up the one-time message on a dead opener).
    if (_disposed) return fallback;
    final peerKey = switch (looked) {
      Ok(:final value) => value,
      Err() => null,
    };
    if (peerKey == null) {
      _wait(m);
      return fallback;
    }
    var savedByEngine = false;
    final result = await engine.decrypt(
      peerUserId: m.senderId,
      peerIdentityKey: peerKey.identityKey,
      ciphertext: cipher,
      olmType: m.olmType!,
      // Written inside the engine's transaction (the store and the engine share one database), so the session never advances without the text; a throw rolls the step back. An unreadable envelope or a hidden row is never written.
      save: store == null
          ? null
          : PlaintextSave.write((decrypted) async {
              final env = decodeEnvelope(decrypted, m.id);
              if (env == null || _forgotten.contains(m.id)) return;
              await store.upsertAll([
                m.withPlain(env.text, env.card, sealed: hash),
              ]);
              // Hidden while this write waited on the disk: take the row out again.
              if (_forgotten.contains(m.id)) await store.remove(m.id);
              savedByEngine = true;
            }),
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
        _publish();
        _remember(slot, plain);
        // The ratchet moved, so this message can never be opened again: the engine saved the text with it (see save above); this write repeats it for an engine that does not run the save, and keeps it in memory even if it fails.
        try {
          if (!savedByEngine) await store?.upsertAll([plain]);
          if (_forgotten.contains(m.id)) await store?.remove(m.id);
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
        _cache?.drop(m.senderId);
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
    _cache?.drop(m.senderId);
    if (!_pending.containsKey(m.id) && _pending.length >= 200) {
      _pending.remove(_pending.keys.first);
    }
    _pending[m.id] = m;
    _publish();
    _schedule();
  }

  /// Waits longer after each try (5 s up to 5 min), five tries, then stops until the next open.
  void _schedule() {
    if (_disposed || _timer != null || _tries >= _retryDelays.length) return;
    _timer = Timer(_retryDelays[_tries++], () {
      _timer = null;
      unawaited(_retryAll());
    });
  }

  Future<void> _retryAll() => _serial<void>(() async {
    if (_disposed) return;
    for (final peer in {for (final m in _pending.values) m.senderId}) {
      if (_disposed) return;
      try {
        await _retryPending(peer, const {});
      } catch (_) {}
    }
    if (_disposed) return;
    if (_pending.isEmpty) {
      _tries = 0;
    } else {
      _schedule();
    }
  });

  @override
  Future<void> openWaiting(String peerUserId) => _serial<void>(() async {
    if (_disposed) return;
    try {
      await _retryPending(peerUserId, const {});
    } catch (_) {}
  });

  /// Opens the rows of [peer] that waited for a session (except [skip], the rows of the call in progress) and sends each one that opened on [reopened].
  Future<void> _retryPending(String peer, Set<String> skip) async {
    final waiting = [
      for (final m in _pending.values)
        if (m.senderId == peer && !skip.contains(m.id)) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final keys = <String, Result<ClaimedKeys?>>{};
    for (final m in waiting) {
      if (_disposed) return;
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
    _publish();
  }
}
