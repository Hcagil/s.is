import '../../../core/failure.dart';

/// Asks the server to delete the signed-in account.
abstract interface class AccountDeletionRepository {
  /// Signs the person in again (proof it is them; Apple accounts also give Apple access back), then requests the deletion.
  /// `Ok` holds the day the account will be removed; the person is signed out everywhere and this phone forgets the session.
  /// An [Err] with a [ProviderFailure] whose `userCanceled` is true means the person backed out of the sign-in.
  Future<Result<DateTime>> requestDeletion();

  /// Of [ids] (any number; asked 200 at a time), the ones whose account no longer exists on the server.
  Future<Result<Set<String>>> missingUsers(List<String> ids);
}
