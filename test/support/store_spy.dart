// A MessageStore that forwards every call to a REAL store and records it, so
// a seam test can see what the controller asked of the store (and when),
// while the answers still come from a real encrypted database. Written from
// the MessageStore contract, never from the implementation.
import 'dart:async';

import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';

class SpyStore implements MessageStore {
  SpyStore(this.inner);

  final MessageStore inner;

  /// Call names in order, e.g. `newest:c1`, `older:c1`, `around:c1:m5`,
  /// `upsert:<ids>`, `reconcile:c1`, `extendOlder:c1`, `remove:m1`, `deleteConversation:c1`,
  /// `search:q:c1`, `syncState:c1`, `clear`.
  final calls = <String>[];

  /// Every read waits this long first: a real disk is never instant.
  Duration readDelay = Duration.zero;

  /// When set, [clear] waits for it (to observe ordering at sign-out).
  Completer<void>? holdClear;

  int count(String prefix) => calls.where((c) => c.startsWith(prefix)).length;

  Future<void> _read() => readDelay > Duration.zero
      ? Future<void>.delayed(readDelay)
      : Future<void>.value();

  @override
  Future<List<Message>> newest(String conversationId, {int limit = 50}) async {
    calls.add('newest:$conversationId');
    await _read();
    return inner.newest(conversationId, limit: limit);
  }

  @override
  Future<List<Message>> older(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) async {
    calls.add('older:$conversationId');
    await _read();
    return inner.older(conversationId, before, limit: limit);
  }

  @override
  Future<List<Message>> around(
    String conversationId,
    String messageId, {
    int each = 50,
  }) async {
    calls.add('around:$conversationId:$messageId');
    await _read();
    return inner.around(conversationId, messageId, each: each);
  }

  @override
  Future<void> upsertAll(List<Message> messages) {
    calls.add('upsert:${[for (final m in messages) m.id].join(',')}');
    return inner.upsertAll(messages);
  }

  @override
  Future<void> reconcilePage(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) {
    calls.add('reconcile:$conversationId');
    return inner.reconcilePage(
      conversationId,
      page,
      reachedStart: reachedStart,
    );
  }

  @override
  Future<void> extendOlder(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) {
    calls.add('extendOlder:$conversationId');
    return inner.extendOlder(conversationId, page, reachedStart: reachedStart);
  }

  @override
  Future<void> remove(String messageId) {
    calls.add('remove:$messageId');
    return inner.remove(messageId);
  }

  @override
  Future<void> deleteConversation(String conversationId) {
    calls.add('deleteConversation:$conversationId');
    return inner.deleteConversation(conversationId);
  }

  @override
  Future<List<Message>> search(
    String query, {
    String? conversationId,
    int limit = 100,
  }) async {
    calls.add('search:$query:$conversationId');
    await _read();
    return inner.search(query, conversationId: conversationId, limit: limit);
  }

  @override
  Future<StoredSync?> syncState(String conversationId) async {
    calls.add('syncState:$conversationId');
    await _read();
    return inner.syncState(conversationId);
  }

  @override
  Future<Set<String>> conversationIds() => inner.conversationIds();

  @override
  Future<ChangeCursor?> cursor() => inner.cursor();

  @override
  Future<void> saveCursor(ChangeCursor cursor) => inner.saveCursor(cursor);

  @override
  Future<void> clear() async {
    calls.add('clear');
    if (holdClear case final held?) await held.future;
    return inner.clear();
  }
}

/// Polls [done] on real time until it holds, or fails after [timeout].
Future<void> eventually(
  FutureOr<bool> Function() done, {
  Duration timeout = const Duration(seconds: 5),
  String reason = '',
}) async {
  final end = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
