// Fakes for the peer key lookup and the on-phone stores, for fake-time tests
// of the openers (no disk, so fake_async drives every timer). Written by qa
// from the MessageStore / ReactionStore / identityVerified contracts, never
// from the implementation.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/reaction_store.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import 'opener_fakes.dart' show keysOf;

enum KeyMode { ok, offline, hang }

/// identityVerified as the server answers it: [mode] decides each call.
/// `hang` never answers until the test calls [releaseAll] (a slow server).
/// [at] records the fake time of each call when [clock] is set.
class ControlledKeys {
  ControlledKeys({this.latency = const Duration(milliseconds: 20)});

  final Duration latency;
  KeyMode mode = KeyMode.ok;
  FakeAsync? clock;
  final calls = <String>[];
  final at = <Duration>[];
  final _held = <Completer<Result<ClaimedKeys?>>>[];

  Future<Result<ClaimedKeys?>> call(String userId) async {
    calls.add(userId);
    if (clock != null) at.add(clock!.elapsed);
    switch (mode) {
      case KeyMode.hang:
        final c = Completer<Result<ClaimedKeys?>>();
        _held.add(c);
        return c.future;
      case KeyMode.offline:
        await Future<void>.delayed(latency);
        return const Err(NetworkFailure('off', retryable: true));
      case KeyMode.ok:
        await Future<void>.delayed(latency);
        return Ok(keysOf(userId));
    }
  }

  /// Answers every held call with keys (the slow server finally answers).
  void releaseAll() {
    for (final c in _held) {
      if (!c.isCompleted) c.complete(Ok(keysOf('bob')));
    }
    _held.clear();
  }

  /// Whole seconds of the calls, deduplicated (one retry pass may look up
  /// several rows at once).
  List<int> get seconds => {for (final d in at) d.inSeconds}.toList();
}

/// A MessageStore in memory: writes keep the newest copy per id.
class MemoryMessageStore implements MessageStore {
  final rows = <String, Message>{};

  List<Message> _of(String c) =>
      rows.values.where((m) => m.conversationId == c).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> upsertAll(List<Message> messages) async {
    for (final m in messages) {
      rows[m.id] = m;
    }
  }

  @override
  Future<void> reconcilePage(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) => upsertAll(page);
  @override
  Future<void> extendOlder(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) => upsertAll(page);
  @override
  Future<List<Message>> newest(String conversationId, {int limit = 50}) async =>
      _of(conversationId).take(limit).toList();
  @override
  Future<List<Message>> older(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) async =>
      _of(conversationId)
          .where((m) => m.createdAt.isBefore(before))
          .take(limit)
          .toList();
  @override
  Future<List<Message>> around(
    String conversationId,
    String messageId, {
    int each = 50,
  }) async => _of(conversationId);
  @override
  Future<void> remove(String messageId) async => rows.remove(messageId);
  @override
  Future<void> deleteConversation(String conversationId) async =>
      rows.removeWhere((_, m) => m.conversationId == conversationId);
  @override
  Future<List<Message>> search(
    String query, {
    String? conversationId,
    int limit = 100,
  }) async => [];
  @override
  Future<StoredSync?> syncState(String conversationId) async => null;
  @override
  Future<ChangeCursor?> cursor() async => null;
  @override
  Future<void> saveCursor(ChangeCursor cursor) async {}
  @override
  Future<Set<String>> conversationIds() async => {
    for (final m in rows.values) m.conversationId,
  };
  @override
  Future<void> clear() async => rows.clear();
}

/// A ReactionStore in memory.
class MemoryReactionStore implements ReactionStore {
  final saved = <String, String>{};

  @override
  Future<String?> emojiOf(
    String messageId,
    String userId,
    String sealed,
  ) async => saved['$messageId|$userId|$sealed'];

  @override
  Future<void> put(
    String messageId,
    String userId,
    String sealed,
    String emoji,
  ) async {
    saved.removeWhere((k, _) => k.startsWith('$messageId|$userId|'));
    saved['$messageId|$userId|$sealed'] = emoji;
  }

  @override
  Future<Map<String, int>> usageOf(String userId, {int limit = 300}) async =>
      {};
}
