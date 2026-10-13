import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/chat_archive_repository.dart';

/// A fake implementation of [ChatArchiveRepository] used in tests.
/// It mirrors the `chat_archives` table per member, recording calls,
/// simulating latency, and allowing the test to control the result
/// and to hold the response until a [Completer] is completed.
class ChatArchiveFake implements ChatArchiveRepository {
  /// Creates a new fake repository.
  ///
  /// * [latency] is the artificial delay before the fake responds.
  /// * [archived] is the initial set of archived conversation IDs.
  ChatArchiveFake({
    this.latency = const Duration(milliseconds: 40),
    Set<String>? archived,
  }) : archived = archived ?? {};

  /// The artificial latency before the fake responds.
  final Duration latency;

  /// The set of archived conversation IDs that the fake keeps in sync
  /// with the server state.
  final Set<String> archived;

  /// Records every call to [setArchived] in the order they were made.
  /// Each entry is a [MapEntry] where `key` is the conversation ID
  /// and `value` is the archived flag.
  final List<MapEntry<String, bool>> calls = [];

  /// The result that will be returned by the next call to [setArchived].
  /// Tests can change this to simulate success or failure.
  Result<void> result = const Ok(null);

  /// When non‑null, the fake will wait for this completer to complete
  /// after the latency before returning the result. This allows a test
  /// to inspect the optimistic state while the server has not yet
  /// responded.
  Completer<void>? hold;

  @override
  Future<Result<void>> setArchived(String conversationId, bool archived) async {
    // Record the call immediately.
    calls.add(MapEntry(conversationId, archived));

    // Simulate network latency.
    await Future.delayed(latency);

    // If a hold is set, wait for it to complete before answering.
    if (hold != null) {
      await hold!.future;
    }

    // Apply the change only if the result is Ok.
    if (result is Ok) {
      if (archived) {
        this.archived.add(conversationId);
      } else {
        this.archived.remove(conversationId);
      }
    }

    return result;
  }
}
