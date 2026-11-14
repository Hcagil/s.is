import 'package:sis/features/admin_panels/domain/admin_draft_store.dart';

/// Test helper that records interactions with an [AdminDraftStore].
class SpyAdminDraftStore implements AdminDraftStore {
  SpyAdminDraftStore([Map<String, String>? initial]) : saved = {...?initial};

  /// Current in‑memory saved drafts.
  Map<String, String> saved;

  /// Number of times [load] was called.
  int loads = 0;

  /// Number of times [save] was called.
  int saves = 0;

  /// Number of times [clear] was called.
  int clears = 0;

  /// Every map passed to [save], in order (deep copies).
  final List<Map<String, String>> saveLog = [];

  /// If true, the next call to [save] will not persist the data.
  bool failSave = false;

  @override
  Future<Map<String, String>> load() async {
    loads++;
    await Future<void>.delayed(Duration.zero);
    return Map.of(saved);
  }

  @override
  Future<void> save(Map<String, String> m) async {
    saves++;
    await Future<void>.delayed(Duration.zero);
    saveLog.add(Map.of(m));
    if (failSave) return;
    saved = Map.of(m);
  }

  @override
  Future<void> clear() async {
    clears++;
    await Future<void>.delayed(Duration.zero);
    saved = {};
  }
}
