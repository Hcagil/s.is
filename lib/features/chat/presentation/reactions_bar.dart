part of 'message_screen.dart';

/// The reactions bar under a tapped message: my ten most used emojis (the picked one lit) and a "+" that opens the full picker grid. Tapping an emoji calls [onPick] with it, or with null when it is already my reaction (tap again removes). This widget never reacts itself: the screen does, so a failure notice can outlive the bar.
class _ReactionsBar extends ConsumerWidget {
  const _ReactionsBar({
    required this.messageId,
    required this.mine,
    required this.onPick,
  });

  final String messageId;
  final bool mine;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final used =
        ref.watch(reactionUsageProvider).value ?? const <String, int>{};
    final emojis = barEmojis(used);
    final me = ref.watch(currentUserIdProvider);
    final current = ref.watch(
      reactionsProvider.select(
        (s) => myReaction(s.value?[messageId] ?? const [], me),
      ),
    );
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Material(
            color: scheme.surfaceContainerHigh,
            elevation: 2,
            shape: StadiumBorder(
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                key: ValueKey('reactions-bar-$messageId'),
                children: [
                  for (final e in emojis)
                    InkResponse(
                      key: ValueKey('reaction-pick-$messageId-$e'),
                      onTap: () => onPick(e == current ? null : e),
                      child: Container(
                        width: 30,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: e == current
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                color: scheme.primary.withValues(alpha: 0.18),
                                border: Border.all(
                                  color: scheme.primary,
                                  width: 1.5,
                                ),
                              )
                            : null,
                        child: Text(e, style: const TextStyle(fontSize: 21)),
                      ),
                    ),
                  const SizedBox(width: 4),
                  // "+" button
                  Builder(
                    builder: (plus) => Semantics(
                      label: l.messageMoreReactions,
                      button: true,
                      child: InkResponse(
                        key: ValueKey('reaction-more-$messageId'),
                        onTap: () => _openPicker(plus, current),
                        child: Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.surface,
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: const Text(
                            '+',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the full emoji grid BELOW the "+" (anchor = the plus button's global rect); a pick goes to onPick like a bar emoji.
  Future<void> _openPicker(BuildContext plus, String? current) async {
    final box = plus.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final picked = await showFloatingCard<String>(
      plus,
      anchor: anchor,
      alignEnd: mine,
      highlightAnchor: false,
      below: true,
      cardKey: const ValueKey('reaction-picker'),
      child: Builder(
        builder: (card) => Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final e in pickerReactionEmojis)
                InkResponse(
                  key: ValueKey('reaction-picker-$e'),
                  onTap: () => Navigator.of(card).pop(e),
                  child: SizedBox(
                    width: 36,
                    height: 38,
                    child: Center(
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onPick(picked == current ? null : picked);
  }
}
