/// A group's own membership history, for the chat's admin-only event lines
/// ("X left", "X was removed", "X was added"). Never shown to a non-admin --
/// the server's own read policy already refuses the rows, so
/// [ChatRepository.groupEvents] simply returns nothing for one; this type
/// carries no visibility flag of its own.
///
/// `picture` is the exception: every member sees it, and it is served by the
/// group_picture_events function, not the admin-only table read. Its subject
/// and actor are both whoever changed the picture.
///
/// `pinned` is served to every member of any chat (a 1:1 too) by the
/// pin_events function; its subject and actor are both whoever pinned the
/// message.
enum GroupEventKind { left, removed, added, picture, pinned }

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
