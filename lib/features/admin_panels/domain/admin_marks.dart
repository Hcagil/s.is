import 'admin_snapshot.dart';

/// A tab's item ids; talk counts only messages not written by the owner.
Map<String, Set<String>> adminTabIds(AdminSnapshot s) {
  return {
    'talk': {
      for (final msg in s.messages)
        if (msg.from != 'owner') msg.id,
    },
    'questions': {for (final q in s.questions) q.id},
    'tasks': {for (final t in s.tasks) t.id},
  };
}

/// How many items on each tab are not seen yet.
Map<String, int> adminNewCounts(
  AdminSnapshot s,
  Map<String, Set<String>>? seen,
) {
  if (seen == null) return {};
  return {
    for (final e in adminTabIds(s).entries)
      e.key: e.value.difference(seen[e.key] ?? const {}).length,
  };
}
