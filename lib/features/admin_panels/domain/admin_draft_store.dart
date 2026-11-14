/// Unsent text of the admin panel boxes kept on the phone (encrypted store; panel content, so never shown before the unlock).
abstract interface class AdminDraftStore {
  /// Saved drafts by key ({} when nothing usable is saved; never throws).
  Future<Map<String, String>> load();

  /// Replaces every saved draft (an empty map removes the entry); best-effort, never throws.
  Future<void> save(Map<String, String> drafts);

  /// Removes all saved drafts; best-effort, never throws.
  Future<void> clear();
}

/// Keeps drafts in memory only (the default until main replaces it).
final class MemoryAdminDraftStore implements AdminDraftStore {
  Map<String, String> _drafts = {};

  @override
  Future<Map<String, String>> load() async => Map.of(_drafts);

  @override
  Future<void> save(Map<String, String> drafts) async =>
      _drafts = Map.of(drafts);

  @override
  Future<void> clear() async => _drafts = {};
}
