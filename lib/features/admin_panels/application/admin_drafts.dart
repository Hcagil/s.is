import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/admin_draft_store.dart';

/// Where the unsent panel text is kept on the phone (set in main; memory only until then).
final adminDraftStoreProvider = Provider<AdminDraftStore>(
  (_) => MemoryAdminDraftStore(),
);

/// Longest saved draft in characters, like the up-message limit.
const adminDraftMax = 8192;

/// Typing waits this long before the draft is written.
const adminDraftDebounce = Duration(milliseconds: 500);

String adminTalkDraftKey(String? conv) => 'talk:${conv ?? 'new'}';

String adminQuestionDraftKey(String id) => 'q:$id';

final adminDraftsProvider = Provider<AdminDrafts>((ref) {
  final d = AdminDrafts(ref.read(adminDraftStoreProvider));
  ref.onDispose(d.dispose);
  return d;
});

/// Unsent panel text by key: debounced writes, nothing loaded before the first read (the panels are unlocked by then). A load still running when [forget] or [wipe] is called is dropped.
class AdminDrafts {
  AdminDrafts(this._store);

  final AdminDraftStore _store;
  Map<String, String>? _cache;
  Future<Map<String, String>>? _loading;
  Timer? _timer;
  int _gen = 0;

  Future<Map<String, String>> _all() {
    final gen = _gen;
    return _loading ??= _store.load().then((m) {
      if (gen == _gen) _cache = m; // a late load after wipe/forget is dropped
      return m;
    });
  }

  Future<String> read(String key) async => (await _all())[key] ?? '';

  /// Blank text removes the draft; longer text is cut to [adminDraftMax].
  Future<void> write(String key, String text) async {
    final gen = _gen;
    final m = await _all();
    if (gen != _gen) return;
    if (text.trim().isEmpty) {
      m.remove(key);
    } else {
      m[key] = text.length > adminDraftMax
          ? text.substring(0, adminDraftMax)
          : text;
    }
    _schedule();
  }

  /// Removes one draft now (it was sent).
  Future<void> remove(String key) async {
    final m = await _all();
    if (m.remove(key) != null) await flush();
  }

  /// Drops drafts under [prefix] whose id is not in [live].
  Future<void> prune(String prefix, Set<String> live) async {
    final gen = _gen;
    final m = await _all();
    if (gen != _gen) return;
    final dead = [
      for (final k in m.keys)
        if (k.startsWith(prefix) && !live.contains(k.substring(prefix.length)))
          k,
    ];
    if (dead.isEmpty) return;
    dead.forEach(m.remove);
    _schedule();
  }

  /// Writes now (leaving a box, app in background).
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final m = _cache;
    if (m != null) await _store.save(Map.of(m));
  }

  /// Writes, then drops the memory copy (panels locked).
  Future<void> forget() async {
    await flush();
    _gen++;
    _cache = null;
    _loading = null;
  }

  /// Sign-out: removes the saved drafts and the memory copy.
  Future<void> wipe() async {
    _gen++;
    _timer?.cancel();
    _timer = null;
    _cache = null;
    _loading = null;
    await _store.clear();
  }

  void dispose() => _timer?.cancel();

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(adminDraftDebounce, () => unawaited(flush()));
  }
}
