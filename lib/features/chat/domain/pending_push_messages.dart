import 'message.dart';

/// Messages a notification saved while the app was closed, not yet
/// received from the server. Shown only, never stored as real messages.
abstract interface class PendingPushMessages {
  /// Lines a plain push saved while the app was closed for [ownerId],
  /// oldest first. Never throws; an unreadable source gives an empty list.
  Future<List<Message>> pendingPushMessages(String ownerId);
}
