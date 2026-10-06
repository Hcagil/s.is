part of 'message_screen.dart';

/// Display facts for each member, keyed by user id; the screen builds it from the roster.
typedef ReaderPeople =
    Map<String, ({String name, String? avatarPath, int? slot})>;

/// The "Seen by N" pill above a tapped message of your own: small rounded pill with up to three reader avatars, "Seen by N" and a chevron. Renders nothing when nobody has read it (hidden receipts included: readersOf only returns members who share their read status). Tapping it opens the readers card above it.
class _SeenByPill extends ConsumerWidget {
  const _SeenByPill({required this.message, required this.people});
  final Message message;
  final ReaderPeople people;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marks = ref.watch(readMarksProvider).value ?? const <ReadMark>[];
    final readers = readersOf(
      marks,
      message.createdAt,
    ); // List<ReadMark>, each has userId and readAt (non-null here)
    if (readers.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final shown = math.min(readers.length, 3);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Builder(
          builder: (pill) => Material(
            color: scheme.surfaceContainerHigh,
            elevation: 2,
            shape: StadiumBorder(
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('seen-by-${message.id}'),
              onTap: () {
                final box = pill.findRenderObject()! as RenderBox;
                final anchor = box.localToGlobal(Offset.zero) & box.size;
                showReadersCard(
                  pill,
                  anchor: anchor,
                  alignEnd: true,
                  readers: [
                    for (final m in readers)
                      Reader(
                        userId: m.userId,
                        name: people[m.userId]?.name ?? 'Member',
                        time: clockTime(m.readAt!),
                        avatarPath: people[m.userId]?.avatarPath,
                        groupSlot: people[m.userId]?.slot,
                      ),
                  ],
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // avatar stack: first three readers overlapping by 8 px
                    SizedBox(
                      width: 22 + 14 * (shown - 1),
                      height: 22,
                      child: Stack(
                        children: [
                          for (int i = 0; i < shown; i++)
                            Positioned(
                              left: 14.0 * i,
                              child: PersonAvatar(
                                radius: 11,
                                label:
                                    people[readers[i].userId]?.name ?? 'Member',
                                seed: readers[i].userId,
                                avatarPath:
                                    people[readers[i].userId]?.avatarPath,
                                groupSlot: people[readers[i].userId]?.slot,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (readers.length > 3) ...[
                      const SizedBox(width: 4),
                      Text(
                        '+${readers.length - 3}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      l.messageSeenBy(readers.length),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
