import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/chat_delete_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';

import 'fakes.dart';

/// [ChatDeleteRepository] as the server behaves: each call takes [latency],
/// is recorded in [calls] ('hide:<id>' / 'deleteDirect:<id>') the moment it
/// is made, and on success removes the row from [chat]'s conversation list,
/// so the next list read no longer returns it -- and on a refusal the row
/// is still there for the reload to bring back.
class ChatDeleteFake implements ChatDeleteRepository {
  ChatDeleteFake({
    this.chat,
    this.latency = const Duration(milliseconds: 40),
    this.journal,
  });

  /// Also receives every call, so a test can order them against another
  /// fake's log (e.g. ChatFake.groupWrites).
  final List<String>? journal;

  /// The "database" behind the list; null when the test does not re-read.
  final ChatFake? chat;
  final Duration latency;
  final calls = <String>[];

  /// Forced answers per call kind; null answers like the real thing.
  Result<void>? hideResult;
  Result<void>? deleteDirectResult;

  /// When set, every call waits on it after [latency].
  Completer<void>? hold;

  @override
  Future<Result<void>> hideChat(String conversationId) =>
      _run('hide:$conversationId', conversationId, hideResult);

  @override
  Future<Result<void>> deleteDirectChat(String conversationId) =>
      _run('deleteDirect:$conversationId', conversationId, deleteDirectResult);

  Future<Result<void>> _run(
    String call,
    String id,
    Result<void>? forced,
  ) async {
    calls.add(call);
    journal?.add(call);
    await Future<void>.delayed(latency);
    final held = hold;
    if (held != null) await held.future;
    final result = forced ?? const Ok<void>(null);
    final store = chat;
    if (result is Ok && store != null) {
      if (store.conversationsResult case Ok(value: final rows)) {
        store.conversationsResult = Ok<List<Conversation>>([
          for (final c in rows)
            if (c.id != id) c,
        ]);
      }
    }
    return result;
  }
}
