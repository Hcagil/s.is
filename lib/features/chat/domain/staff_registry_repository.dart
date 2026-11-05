import '../../../core/failure.dart';
import 'staff_registry.dart';

/// Staff registry boundary; the only way the app reads the staff chats and their commands. A repository never throws: a refusal arrives as [Err] with a typed [Failure].
abstract interface class StaffRegistryRepository {
  /// The last stored registry, null if none; reads local storage only, never the network.
  Future<StaffRegistry?> cached();

  /// Asks the server and stores the answer; an empty answer replaces the stored one.
  Future<Result<StaffRegistry>> refresh();

  /// Forgets the stored registry (sign-out).
  Future<void> clear();
}
