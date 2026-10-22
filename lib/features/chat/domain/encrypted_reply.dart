/// One Reply typed into a private-chat notification, waiting to be sent.
final class PendingReply {
  /// Creates a waiting reply.
  const PendingReply({
    required this.id,
    required this.conversationId,
    required this.userId,
    required this.text,
  });

  /// Message id made when the member tapped Send in the notification (a retry keeps it).
  final String id;

  /// The chat the notification belongs to.
  final String conversationId;

  /// The member the notification was for; the reply is dropped if another member is signed in.
  final String userId;

  /// The typed text; held in memory only.
  final String text;
}

/// The door a notification Reply reaches the app through (Android: EncryptedReplyActivity, iPhone: AppDelegate). The host never encrypts or sends; Dart sends it through the normal encrypted send queue.
abstract interface class EncryptedReplyIntake {
  /// Hands over every waiting reply and forgets them; empty when none. Never throws.
  Future<List<PendingReply>> take();

  /// Fires when a reply arrives while the app is already running.
  Stream<void> get arrivals;
}
