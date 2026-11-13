/// Which item ids the owner has already seen, per tab (keys talk, questions, tasks).
/// Every method is best-effort and never throws.
abstract interface class AdminSeenStore {
  /// The saved ids, or null when nothing usable is saved.
  Future<Map<String, Set<String>>?> load();

  /// Replaces whatever was saved.
  Future<void> save(Map<String, Set<String>> seen);

  /// Removes it.
  Future<void> clear();
}

/// Keeps it in memory only (the default until main replaces it).
final class MemoryAdminSeenStore implements AdminSeenStore {
  Map<String, Set<String>>? _seen;

  @override
  Future<Map<String, Set<String>>?> load() async => _seen;

  @override
  Future<void> save(Map<String, Set<String>> seen) async {
    _seen = {
      for (final e in seen.entries) e.key: {...e.value},
    };
  }

  @override
  Future<void> clear() async {
    _seen = null;
  }
}
