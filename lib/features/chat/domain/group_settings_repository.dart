import '../../../core/failure.dart';
import 'group_event.dart';

/// A nudge from the server: something about one group changed. [what] is
/// 'settings', 'picture', 'members' or 'deleted'.
typedef GroupChange = ({String conversationId, String what});

/// Group settings boundary; the only way the app reaches group settings. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. Row-level security decides what is returned.
abstract interface class GroupSettingsRepository {
  /// Sets the group settings for [conversationId]. Admin-only; null values leave settings unchanged. DeniedFailure when the caller is not an admin.
  Future<Result<void>> setSettings(
    String conversationId, {
    bool? membersCanSetAvatar,
    bool? membersCanAdd,
    bool? newMembersSeeHistory,
  });

  /// Closes the group [conversationId] for good (server function close_group). Admin-only; every member, the admin too, is removed and keeps the chat read-only; it cannot be reopened. DeniedFailure when the caller is not an admin or the group is already closed.
  Future<Result<void>> closeGroup(String conversationId);

  /// Returns the "X closed the group" event (GroupEventKind.closed) for [conversationId], at most one. Any member, also a removed one, may read it.
  Future<Result<List<GroupEvent>>> closeEvents(String conversationId);

  /// Returns the "X changed the group picture" events (GroupEventKind.picture) for [conversationId], oldest first. Any member may read these events.
  Future<Result<List<GroupEvent>>> pictureEvents(String conversationId);

  /// Returns a stream of [GroupChange]s (settings, picture, members or existence of a group) (live), for the signed-in member; resolves once subscribed.
  Future<Result<Stream<GroupChange>>> groupChanges();
}
