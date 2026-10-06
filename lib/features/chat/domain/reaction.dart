/// One member's emoji reaction on one message.
final class Reaction {
  const Reaction({
    required this.messageId,
    required this.userId,
    required this.emoji,
  });

  final String messageId;
  final String userId;

  /// null = the reaction was removed.
  final String? emoji;
}

/// The ten emojis the reactions bar offers a member who has not used any yet.
const defaultReactionEmojis = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '🙏',
  '🔥',
  '👏',
  '😍',
  '🎉',
];

/// How many emojis the reactions bar shows before the "+".
const reactionBarSize = 10;

/// The "+" picker: a curated grid of common emojis (not all of Unicode).
const pickerReactionEmojis = <String>[
  ...['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃'],
  ...['😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😋', '😜', '🤪'],
  ...['🤗', '🤭', '🤔', '😐', '🙄', '😬', '😌', '😴', '🤒', '🤯'],
  ...['🥳', '😎', '🥺', '😢', '😭', '😱', '😤', '😡', '🤬', '💀'],
  ...['💩', '🤡', '👻', '🙈', '👋', '👌', '✌️', '🤞', '🤟', '🤘'],
  ...['👍', '👎', '👊', '✊', '👏', '🙌', '🙏', '💪', '🤝', '🫶'],
  ...['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '💕'],
  ...['💯', '🔥', '✨', '⭐', '🎉', '🎂', '🎁', '🍀', '🌹', '☀️'],
  ...['🐶', '🐱', '🦊', '🐻', '🐼', '🦁', '🐸', '🦄', '🍕', '🍔'],
  ...['🍺', '☕', '⚽', '🚗', '✈️', '🏠', '📌', '✅', '❌', '❓'],
];

/// Reactions grouped by message id; never holds a reaction with a null emoji.
typedef ReactionsByMessage = Map<String, List<Reaction>>;

/// A NEW map in which [reaction] replaces whatever that user reacted with on
/// that message (one reaction per user per message). A null emoji removes it,
/// and a message left with no reactions leaves the map. Never mutates [map].
ReactionsByMessage applyReaction(ReactionsByMessage map, Reaction reaction) {
  final next = {
    for (final e in map.entries)
      if (e.key != reaction.messageId) e.key: e.value,
  };
  final kept = [
    for (final r in map[reaction.messageId] ?? const <Reaction>[])
      if (r.userId != reaction.userId) r,
    if (reaction.emoji != null) reaction,
  ];
  if (kept.isNotEmpty) next[reaction.messageId] = kept;
  return next;
}

/// A map built from a flat list: null emojis are skipped, and the last entry
/// for the same (message, user) wins.
ReactionsByMessage groupReactions(Iterable<Reaction> reactions) {
  var map = <String, List<Reaction>>{};
  for (final r in reactions) {
    map = applyReaction(map, r);
  }
  return map;
}

/// One chip under a bubble: an emoji, how many people used it, and whether
/// the viewer is one of them.
final class ReactionChip {
  const ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
  });

  final String emoji;
  final int count;
  final bool mine;
}

/// The chips for one message: one per distinct emoji, biggest count first;
/// equal counts keep the order the emojis first appeared in [reactions].
List<ReactionChip> reactionChips(List<Reaction> reactions, String? me) {
  final counts = <String, int>{};
  final mine = <String>{};
  for (final r in reactions) {
    final emoji = r.emoji;
    if (emoji == null) continue;
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    if (r.userId == me) mine.add(emoji);
  }
  final order = counts.keys.toList();
  // List.sort is not stable: the first-seen index breaks ties explicitly.
  order.sort((a, b) {
    final byCount = counts[b]!.compareTo(counts[a]!);
    return byCount != 0
        ? byCount
        : order.indexOf(a).compareTo(order.indexOf(b));
  });
  return [
    for (final e in order)
      ReactionChip(emoji: e, count: counts[e]!, mine: mine.contains(e)),
  ];
}

/// The emoji [me] reacted with in [reactions], or null.
String? myReaction(List<Reaction> reactions, String? me) {
  for (final r in reactions) {
    if (r.userId == me) return r.emoji;
  }
  return null;
}

/// The reactions bar: the member's most used emojis first ([used] maps an
/// emoji to how often they used it; ties alphabetical), topped up from
/// [defaultReactionEmojis] until there are [reactionBarSize].
List<String> barEmojis(Map<String, int> used) {
  final top = used.keys.toList()
    ..sort((a, b) {
      final byCount = used[b]!.compareTo(used[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return [
    ...top,
    ...defaultReactionEmojis.where((e) => !used.containsKey(e)),
  ].take(reactionBarSize).toList();
}
