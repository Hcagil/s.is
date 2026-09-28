import '../../../core/failure.dart';
import '../../auth/domain/member.dart';

/// A member's own contacts, and the exact-tag lookup that finds someone not
/// already reachable through "your people" (a contact or someone you share a
/// conversation with). Row-level security scopes every call to the caller.
abstract interface class ContactsRepository {
  /// The one allowlisted member whose tag (leading `@` optional) matches
  /// exactly, or null when nobody has it. Never a partial or prefix match.
  ///
  /// Rate-limited server-side; a limit hit comes back as [Err] with a
  /// [ProviderFailure] whose message is exactly "Too many searches, try
  /// again later." -- the app shows that message as-is, and must not retry
  /// automatically.
  Future<Result<Member?>> findByTag(String tag);

  /// Saves [userId] to the caller's own contacts. Idempotent: adding someone
  /// already saved succeeds without creating a second row.
  Future<Result<void>> add(String userId);

  /// Removes [userId] from the caller's own contacts. Succeeds even if they
  /// were never saved.
  Future<Result<void>> remove(String userId);

  /// Every contact's user id, for deciding whether to show "Add to
  /// contacts" or "Remove from contacts" for a given person.
  Future<Result<Set<String>>> ids();
}
