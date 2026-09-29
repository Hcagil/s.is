import '../../auth/domain/member.dart';

/// One row of a group's roster: the [member] plus their role and, once they
/// have gone, how.
enum LeftReason { left, removed }

final class GroupMember {
  const GroupMember({
    required this.member,
    required this.isAdmin,
    this.leftReason,
  });

  final Member member;
  final bool isAdmin;

  /// null while the member is current; set once they have left or been
  /// removed. Their past messages stay visible; this is what greys their
  /// name and puts them in the roster's "left" section.
  final LeftReason? leftReason;

  bool get hasLeft => leftReason != null;
}
