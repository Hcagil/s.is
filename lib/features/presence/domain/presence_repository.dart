import '../../../core/failure.dart';

/// Who is online, and who is typing where.
///
/// Both travel over private Realtime channels that the server authorises with
/// the same rules as everything else: an active allowlisted member for online
/// status, a member of the conversation for typing. A member who turned
/// sharing off is refused by the server when announcing, not only by the app.
abstract interface class PresenceRepository {
  /// The ids of members online now, re-emitted whenever someone comes or goes.
  /// The caller is announced only when [share] is true; either way they can
  /// see others. Resolves once the server has confirmed the channel.
  Future<Result<Stream<Set<String>>>> online({required bool share});

  /// Typing signals in [conversationId]: each event is the id of a member who
  /// just typed. The caller's own signals are not echoed back.
  Future<Result<TypingChannel>> typing(String conversationId);
}

/// An open typing channel for one conversation.
abstract interface class TypingChannel {
  Stream<String> get typists;

  /// Tells the others the caller is typing. Best effort: a refused or failed
  /// signal is dropped, never surfaced — a missing "typing…" is not an error.
  Future<void> signal();

  Future<void> close();
}
