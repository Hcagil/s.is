/// A group's three admin-controlled switches. The defaults are what a newly created group gets.
final class GroupSettings {
  const GroupSettings({
    this.membersCanSetAvatar = false,
    this.membersCanAdd = true,
    this.newMembersSeeHistory = true,
  });

  final bool membersCanSetAvatar;
  final bool membersCanAdd;
  final bool newMembersSeeHistory;

  GroupSettings copyWith({
    bool? membersCanSetAvatar,
    bool? membersCanAdd,
    bool? newMembersSeeHistory,
  }) {
    return GroupSettings(
      membersCanSetAvatar: membersCanSetAvatar ?? this.membersCanSetAvatar,
      membersCanAdd: membersCanAdd ?? this.membersCanAdd,
      newMembersSeeHistory: newMembersSeeHistory ?? this.newMembersSeeHistory,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'membersCanSetAvatar': membersCanSetAvatar,
      'membersCanAdd': membersCanAdd,
      'newMembersSeeHistory': newMembersSeeHistory,
    };
  }

  static GroupSettings fromJson(Map<String, Object?> json) {
    return GroupSettings(
      membersCanSetAvatar: json['membersCanSetAvatar'] as bool? ?? false,
      membersCanAdd: json['membersCanAdd'] as bool? ?? true,
      newMembersSeeHistory: json['newMembersSeeHistory'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;
    return other is GroupSettings &&
        other.membersCanSetAvatar == membersCanSetAvatar &&
        other.membersCanAdd == membersCanAdd &&
        other.newMembersSeeHistory == newMembersSeeHistory;
  }

  @override
  int get hashCode =>
      Object.hash(membersCanSetAvatar, membersCanAdd, newMembersSeeHistory);
}
