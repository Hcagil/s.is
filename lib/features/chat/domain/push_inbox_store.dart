import 'message.dart';

/// Read side of the push_inbox table: text the notification opened with an already stored key. It is shown only, never treated as a stored message (see docs/SECURITY.md). Separate from MessageStore so existing fakes of MessageStore keep working.
abstract interface class PushInboxStore {
  /// Messages the notification saved while the app was closed and the app has not yet received itself, oldest first, from every chat. Never throws; an unreadable store gives an empty list.
  Future<List<Message>> pushInbox();

  /// Deletes the rows received before [before] (the ones a finished store sync did not confirm). Never throws.
  Future<void> sweepPushInbox(DateTime before);
}
