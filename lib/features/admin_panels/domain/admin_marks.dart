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

/// How many items on each tab are not seen yet; talk counts conversations with unread manager messages (the computer's `seen`/`mat`, plus what this phone [readUpto]).
Map<String, int> adminNewCounts(
  AdminSnapshot s,
  Map<String, Set<String>>? seen, [
  Map<String, int> readUpto = const {},
]) {
  if (seen == null) return {};
  return {
    for (final e in adminTabIds(s).entries)
      e.key: e.key == 'talk'
          ? s.conversations.where((c) => c.isUnread(readUpto[c.id] ?? 0)).length
          : e.value.difference(seen[e.key] ?? const {}).length,
  };
}
