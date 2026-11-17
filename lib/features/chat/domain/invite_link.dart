import '../../../core/failure.dart';
import 'group_event.dart';

/// The invite code of one group; admins only.
final class InviteLink {
  const InviteLink({
    required this.token,
    required this.createdAt,
    this.expiresAt,
    this.validDays,
  });

  final String token;
  final DateTime createdAt;
  final DateTime? expiresAt;

  /// The chosen time limit in days (1, 7 or 30); null = no limit.
  final int? validDays;

  /// Returns true if [expiresAt] is not after [now], or if there is no expiry.
  bool expiredAt(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);
}

/// What a person sees before joining: only name, picture and member count.
final class InvitePreview {
  const InvitePreview({
    required this.conversationId,
    required this.title,
    required this.memberCount,
    this.avatarPath,
    this.newMembersSeeHistory,
  });

  final String conversationId;
  final String title;
  final int memberCount;
  final String? avatarPath;

  /// Whether new members see earlier messages; null when the server did not say.
  final bool? newMembersSeeHistory;
}

/// Matches a 24-character invite code (alphanumeric, underscore, hyphen).
final RegExp inviteCodePattern = RegExp(r'^[A-Za-z0-9_-]{24}$');

/// The code from a pasted invite, which is either the bare code or a web address ending in it; null when it is not a code.
String? inviteCodeFrom(String pasted) {
  final code = pasted.trim().split(RegExp(r'[/#=]')).last;
  return inviteCodePattern.hasMatch(code) ? code : null;
}

/// What an admin copies: the bare code while the web address [base] is empty.
String inviteText(String code, String base) =>
    base.isEmpty ? code : '$base/$code';

/// Invite link boundary; the only way the app reaches invite links.
abstract interface class InviteLinkRepository {
  /// Admin: the group's link, null when none.
  Future<Result<InviteLink?>> inviteLink(String conversationId);

  /// Admin: makes a new link, the old one stops working; validDays null (no limit), 1, 7 or 30.
  Future<Result<InviteLink>> resetInviteLink(
    String conversationId, {
    int? validDays,
  });

  /// Admin: a new time limit (null = none, 1, 7 or 30 days) on the same link; its timer restarts. Err(InviteLinkFailure(invalid)) when the group has no link.
  Future<Result<InviteLink>> setInviteLinkExpiry(
    String conversationId, {
    int? validDays,
  });

  /// Admin: no link until an admin makes a new one.
  Future<Result<void>> turnOffInviteLink(String conversationId);

  /// Err(InviteLinkFailure) when the link cannot be used; Err(SearchLimitFailure) on the rate limit.
  Future<Result<InvitePreview>> previewInvite(String code);

  /// Ok = the group's conversation id; same failures as previewInvite.
  Future<Result<String>> joinByInvite(String code);

  /// The "X joined by link" lines (GroupEventKind.joined), oldest first; any member may read.
  Future<Result<List<GroupEvent>>> joinEvents(String conversationId);
}
