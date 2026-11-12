import 'admin_snapshot.dart';

/// The last complete admin snapshot kept on the phone, with where it stands.
final class AdminSavedSnapshot {
  const AdminSavedSnapshot({
    required this.epoch,
    required this.lastId,
    required this.snapshot,
  });

  /// The key epoch the snapshot belongs to.
  final int epoch;

  /// The id of the newest down row already applied (fetch only rows after it).
  final int lastId;

  final AdminSnapshot snapshot;
}

/// Where the last snapshot lives on the phone (encrypted store). Every method is best-effort and never throws.
abstract interface class AdminSnapshotStore {
  /// The saved snapshot, or null when nothing usable is saved (corrupt data is deleted).
  Future<AdminSavedSnapshot?> load();

  /// Replaces whatever was saved.
  Future<void> save(AdminSavedSnapshot saved);

  /// Removes it.
  Future<void> clear();
}
