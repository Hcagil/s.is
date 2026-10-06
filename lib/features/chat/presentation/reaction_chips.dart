part of 'message_screen.dart';

/// The chips under one bubble: one per distinct emoji with its count, the
/// member's own highlighted. Renders nothing when the message has no
/// reactions. Watches ONLY this message's list (the reactions provider
/// replaces a message's list only when that message changes), so a reaction
/// elsewhere does not rebuild this row.
class _ReactionChips extends ConsumerWidget {
  const _ReactionChips({required this.messageId, required this.mine});

  final String messageId;

  /// The bubble's side: the chips align to it.
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reactions = ref.watch(
      reactionsProvider.select((s) => s.value?[messageId]),
    );
    if (reactions == null || reactions.isEmpty) return const SizedBox.shrink();
    final me = ref.watch(currentUserIdProvider);
    final chips = reactionChips(reactions, me);
    final scheme = Theme.of(context).colorScheme;
    final brand = SisBrand.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Wrap(
            key: ValueKey('reactions-$messageId'),
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final c in chips)
                Container(
                  key: ValueKey('reaction-chip-$messageId-${c.emoji}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.mine
                        ? scheme.primary.withValues(alpha: 0.18)
                        : brand.theirs,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: c.mine ? scheme.primary : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Text(
                    c.count > 1 ? '${c.emoji} ${c.count}' : c.emoji,
                    style: TextStyle(fontSize: 13, color: brand.text),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
