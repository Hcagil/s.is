/// A group's own membership history, for the chat's admin-only event lines
/// ("X left", "X was removed", "X was added"). Never shown to a non-admin --
/// the server's own read policy already refuses the rows, so
/// [ChatRepository.groupEvents] simply returns nothing for one; this type
/// carries no visibility flag of its own.
enum GroupEventKind { left, removed, added }

final class GroupEvent {
  const GroupEvent({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.subjectId,
    required this.createdAt,
    this.actorId,
  });

  final String id;
  final String conversationId;
  final GroupEventKind kind;

  /// Who this event is about: who left, was removed, or was added.
  final String subjectId;

  /// Who did it: an admin, for [GroupEventKind.removed] and
  /// [GroupEventKind.added]; null for [GroupEventKind.left] -- nobody but
  /// the member themselves "does" a leave.
  final String? actorId;

  final DateTime createdAt;
}
