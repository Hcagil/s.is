import 'read_marks.dart';

/// Where the read and delivery marks of a conversation live on the phone, so
/// the seen ticks and the readers card still show offline.
///
/// Every method is best-effort and never throws.
abstract interface class ReadMarkStore {
  /// Last saved marks of [conversationId]; empty when none or the storage failed.
  Future<List<ReadMark>> load(String conversationId);

  /// Replaces ALL stored marks of [conversationId] with [marks], so a member
  /// who stopped sharing no longer has a stored read time.
  Future<void> save(String conversationId, List<ReadMark> marks);
}
