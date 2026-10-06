part of 'profile_pages.dart';

/// A member's page: who they are, whether they are around, and what you have
/// shared with them in your 1:1 chat.
class PersonScreen extends ConsumerWidget {
  const PersonScreen({
    super.key,
    required this.userId,
    this.fallbackName,
    this.fallbackAvatarPath,
    this.showMessage = true,
  });

  final String userId;

  /// Shown until (or if never) the member list names them.
  final String? fallbackName;

  /// Shown until (or if never) a live lookup finds their picture.
  final String? fallbackAvatarPath;

  /// Off when the page was opened from your chat with them: you are there.
  final bool showMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final member = (ref.watch(yourPeopleProvider).value ?? const <Member>[])
        .where((m) => m.userId == userId)
        .firstOrNull;
    final l = AppLocalizations.of(context);
    final name = member?.displayName ?? fallbackName ?? l.commonMember;
    // Your 1:1 with them, if one exists. The page never creates one just to
    // look; the Message button does.
    final direct = (ref.watch(conversationListProvider).value ?? const [])
        .where((c) => !c.isGroup && c.other?.userId == userId)
        .firstOrNull;
    final avatarPath = fallbackAvatarPath ?? member?.avatarPath;
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(),
        body: Column(
          children: [
            GestureDetector(
              key: const ValueKey('person-avatar'),
              onTap: avatarPath == null
                  ? null
                  : () => openPhotoViewer(
                      context,
                      [avatarPath],
                      0,
                      isAvatar: true,
                    ),
              child: PersonAvatar(
                label: name,
                seed: userId,
                radius: 48,
                avatarPath: avatarPath,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              name,
              key: const ValueKey('person-name'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (member?.tag != null)
              Text(
                '@${member!.tag}',
                key: const ValueKey('person-tag'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            _Status(userId),
            if (showMessage)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('person-message'),
                    onPressed: () => _message(context, ref, name, direct?.id),
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    label: Text(l.commonMessage),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            _ContactButton(userId),
            // Muting a person silences them in every chat, groups included.
            MuteTile(kind: MuteKind.person, target: userId),
            // Your 1:1 with them: its own sound and vibration.
            if (direct != null) ChatAlertTiles(conversationId: direct.id),
            const SizedBox(height: 12),
            const TabBar(
              tabs: [
                Tab(key: ValueKey('tab-media'), text: 'Media'),
                Tab(key: ValueKey('tab-links'), text: 'Links'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _MediaTab(direct?.id),
                  _LinksTab(direct?.id, names: {userId: name}),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _message(
    BuildContext context,
    WidgetRef ref,
    String name,
    String? existing,
  ) async {
    var id = existing;
    if (id == null) {
      final started = await ref
          .read(conversationListProvider.notifier)
          .startWith(userId);
      if (!context.mounted) return;
      switch (started) {
        case Ok(:final value):
          id = value;
        case Err(:final failure):
          showSisNotice(context, failure.message, isError: true);
          return;
      }
    }
    await openConversation(context, ref, id, title: name, otherUserId: userId);
  }
}

/// "Add to contacts" / "Remove from contacts". Hidden for the caller's own
/// page and while the caller's own contacts are still loading, so it never
/// shows one label and then flips to the other moments later.
class _ContactButton extends ConsumerWidget {
  const _ContactButton(this.userId);

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(contactsControllerProvider).value;
    if (ids == null || userId == ref.watch(currentUserIdProvider)) {
      return const SizedBox.shrink();
    }
    final isContact = ids.contains(userId);
    return SisSettingsRow(
      key: const ValueKey('person-contact-toggle'),
      icon: isContact
          ? Icons.person_remove_outlined
          : Icons.person_add_alt_1_outlined,
      title: isContact
          ? AppLocalizations.of(context).contactRemove
          : AppLocalizations.of(context).contactAdd,
      onTap: () async {
        final notifier = ref.read(contactsControllerProvider.notifier);
        final result = isContact
            ? await notifier.remove(userId)
            : await notifier.add(userId);
        if (result case Err(:final failure) when context.mounted) {
          showSisNotice(context, failure.message, isError: true);
        }
      },
    );
  }
}

/// "online", else "last seen …", else nothing.
class _Status extends ConsumerWidget {
  const _Status(this.userId);

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(onlineMembersProvider).contains(userId);
    final at = online ? null : ref.watch(lastSeenProvider(userId)).value;
    final l = AppLocalizations.of(context);
    final text = online
        ? l.statusOnline
        : at == null
        ? null
        : lastSeenText(l, at, DateTime.now());
    if (text == null) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        key: const ValueKey('person-status'),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
