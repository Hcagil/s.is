import '../../../core/failure.dart';

/// Asks the server to add the "What's new" notes due for this installed build
/// to the member's SIS chat.
///
/// Returns `Ok(true)` when a call was made and succeeded, `Ok(false)` when this
/// build was already served for [userId] on this device (nothing asked), `Err`
/// on failure (retried at next start).
abstract interface class ReleaseNotesDelivery {
  Future<Result<bool>> deliver(String userId);
}
