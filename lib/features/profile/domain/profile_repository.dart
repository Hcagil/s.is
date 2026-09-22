import '../../../core/failure.dart';
import 'own_profile.dart';

/// The signed-in member's own profile. Every write is pinned to the caller by
/// row-level security; nothing here can touch another member's profile.
abstract interface class ProfileRepository {
  Future<Result<OwnProfile>> load();

  /// Saves whichever fields are given. A tag taken by someone else between
  /// the availability check and this call comes back as an [Err] with a
  /// reason, never as a partial save: the update is one statement.
  Future<Result<OwnProfile>> save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
  });

  /// Whether [tag] is free for this member (their own current tag counts as
  /// free). Advisory: the server's unique index is the authority.
  Future<Result<bool>> isTagAvailable(String tag);
}
