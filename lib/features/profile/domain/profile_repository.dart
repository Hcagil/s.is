import '../../../core/failure.dart';
import '../../chat/domain/attachment.dart';
import 'own_profile.dart';

/// The signed-in member's own profile. Every write is pinned to the caller by
/// row-level security; nothing here can touch another member's profile.
abstract interface class ProfileRepository {
  Future<Result<OwnProfile>> load();

  /// Saves whichever fields are given. A tag taken by someone else between
  /// the availability check and this call comes back as an [Err] with a
  /// reason, never as a partial save: the update is one statement.
  ///
  /// Only given fields change; [avatarVisibility] follows the same rule.
  Future<Result<OwnProfile>> save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
    bool? sharePresence,
    bool? shareTyping,
    bool? shareLastSeen,
    bool? shareReadStatus,
    AvatarVisibility? avatarVisibility,
  });

  /// Uploads [image] as the member's own picture, replacing any previous one,
  /// and returns the updated profile. [previousPath] (the profile's
  /// avatarPath before this call, if any) is deleted from storage after the
  /// new one is written -- the caller already has it from the current state
  /// and passing it here avoids an extra round trip.
  Future<Result<OwnProfile>> setAvatar(
    PickedImage image, {
    String? previousPath,
  });

  /// Clears the member's picture (avatarPath becomes null) and deletes
  /// [previousPath] from storage.
  Future<Result<OwnProfile>> removeAvatar(String previousPath);

  /// Whether [tag] is free for this member (their own current tag counts as
  /// free). Advisory: the server's unique index is the authority.
  Future<Result<bool>> isTagAvailable(String tag);
}
