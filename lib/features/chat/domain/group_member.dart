import '../../auth/domain/member.dart';

/// One row of a group's roster: the [member] plus their role and, once they
/// have gone, how.
enum LeftReason { left, removed }

final class GroupMember {
  const GroupMember({
    required this.member,
    required this.isAdmin,
    this.leftReason,
    this.colorSlot = 0,
  });

  final Member member;
  final bool isAdmin;

  /// null while the member is current; set once they have left or been
  /// removed. Their past messages stay visible; this is what greys their
  /// name and puts them in the roster's "left" section.
  final LeftReason? leftReason;

  /// The colour slot (0..9) the server gave this person in this group, kept
  /// for good; see groupColorArgb.
  final int colorSlot;

  bool get hasLeft => leftReason != null;
}
