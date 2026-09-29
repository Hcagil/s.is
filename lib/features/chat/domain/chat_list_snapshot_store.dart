import 'conversation.dart';

/// Where the conversation list's last snapshot lives on the phone, so the
/// list can show instantly on a cold start, before the server answers.
///
/// Every method is best-effort and must never throw: a snapshot is a
/// convenience for the first frame, never a source of truth, so a failed
/// read or write only costs that instant, never a failure the member sees.
abstract interface class ChatListSnapshotStore {
  /// The last saved list for [ownerId], in the order it was saved. Null when
  /// there is nothing saved, it belongs to a different owner, it was written
  /// by an old or unknown schema, it is corrupt, or the storage itself
  /// failed to read -- in every one of those cases the snapshot is also
  /// deleted, so a bad file is never retried.
  Future<List<Conversation>?> load(String ownerId);

  /// Saves [conversations] as the snapshot for [ownerId], replacing whatever
  /// was stored before, for any owner.
  Future<void> save(String ownerId, List<Conversation> conversations);

  /// Removes the snapshot, if any.
  Future<void> clear();
}
