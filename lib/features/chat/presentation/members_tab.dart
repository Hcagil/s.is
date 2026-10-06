part of 'profile_pages.dart';

class _MembersTab extends ConsumerWidget {
  const _MembersTab(this.conversationId, {required this.title});

  final String conversationId;

  /// The group's name, shown on the add-members page.
  final String title;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    GroupMember m,
  ) async {
    final result = await ref
        .read(groupControllerProvider)
        .removeMember(conversationId, m.member.userId);
    if (!context.mounted) return;
    switch (result) {
      case Ok():
        showSisNotice(
          context,
          AppLocalizations.of(context).membersRemoved(
            nameOrMember(AppLocalizations.of(context), m.member.displayName),
          ),
        );
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  Future<void> _setAdmin(
    BuildContext context,
    WidgetRef ref,
    GroupMember m,
    bool isAdmin,
  ) async {
    final result = await ref
        .read(groupControllerProvider)
        .setAdmin(conversationId, m.member.userId, isAdmin: isAdmin);
    if (!context.mounted) return;
    switch (result) {
      case Ok():
        final l = AppLocalizations.of(context);
        showSisNotice(
          context,
          isAdmin
              ? l.membersNowAdmin(nameOrMember(l, m.member.displayName))
              : l.membersNoLongerAdmin(nameOrMember(l, m.member.displayName)),
        );
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final box = context.findRenderObject() as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final confirmed = await showFloatingCard<bool>(
      context,
      anchor: anchor,
      highlightAnchor: false,
      cardKey: const ValueKey('leave-card'),
      child: Builder(
        builder: (card) {
          final l = AppLocalizations.of(card);
          final scheme = Theme.of(card).colorScheme;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.groupLeaveTitle,
                  style: Theme.of(card).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(l.groupLeaveBody),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('leave-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: () => Navigator.of(card).pop(true),
                  child: Text(l.groupLeave),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('leave-cancel'),
                  onPressed: () => Navigator.of(card).pop(false),
                  child: Text(l.groupLeaveCancel),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await ref
        .read(groupControllerProvider)
        .leave(conversationId);
    if (!context.mounted) return;
    switch (result) {
      case Ok(:final value):
        showSisNotice(
          context,
          value
              ? AppLocalizations.of(context).groupLeftUnsentNotice
              : AppLocalizations.of(context).groupLeftNotice,
        );
        Navigator.of(context).pop();
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    final online = ref.watch(onlineMembersProvider);
    final l = AppLocalizations.of(context);
    return _Async(
      ref.watch(groupRosterProvider(conversationId)),
      empty: l.membersEmpty,
      builder: (roster) {
        final current = [
          for (final m in roster)
            if (!m.hasLeft) m,
        ];
        final departed = [
          for (final m in roster)
            if (m.hasLeft) m,
        ];
        final amAdmin =
            current.where((m) => m.member.userId == me).firstOrNull?.isAdmin ??
            false;
        return ListView(
          children: [
            if (amAdmin)
              SisSettingsRow(
                key: const ValueKey('add-members'),
                icon: Icons.person_add_alt_1_outlined,
                title: l.commonAddMembers,
                onTap: () => showAddMembersPage(
                  context,
                  ref,
                  conversationId,
                  current: {for (final m in current) m.member.userId},
                  groupTitle: title,
                ),
              ),
            for (final m in current)
              _MemberRow(
                key: ValueKey('group-member-${m.member.userId}'),
                avatar: PersonAvatar(
                  label: nameOrMember(l, m.member.displayName),
                  seed: m.member.userId,
                  online: online.contains(m.member.userId),
                  avatarPath: m.member.avatarPath,
                  groupSlot: m.colorSlot,
                  radius: 18,
                ),
                title: m.member.userId == me
                    ? l.membersYou(nameOrMember(l, m.member.displayName))
                    : nameOrMember(l, m.member.displayName),
                subtitle: [
                  if (m.isAdmin) l.membersAdmin,
                  if (m.member.tag != null) '@${m.member.tag}',
                ].join(' · '),
                trailing: amAdmin && m.member.userId != me
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('toggle-admin-${m.member.userId}'),
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              m.isAdmin
                                  ? Icons.remove_moderator_outlined
                                  : Icons.admin_panel_settings_outlined,
                            ),
                            tooltip: m.isAdmin
                                ? l.membersRemoveAdmin
                                : l.membersMakeAdmin,
                            onPressed: () =>
                                _setAdmin(context, ref, m, !m.isAdmin),
                          ),
                          IconButton(
                            key: ValueKey('remove-member-${m.member.userId}'),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.person_remove_outlined),
                            tooltip: l.commonRemove,
                            onPressed: () => _remove(context, ref, m),
                          ),
                        ],
                      )
                    : null,
                // Your own row leads nowhere; everyone else's to their page.
                onTap: m.member.userId == me
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PersonScreen(
                            userId: m.member.userId,
                            fallbackName: nameOrMember(l, m.member.displayName),
                            fallbackAvatarPath: m.member.avatarPath,
                          ),
                        ),
                      ),
              ),
            if (departed.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  l.membersLeft,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final m in departed)
                _MemberRow(
                  key: ValueKey('group-member-${m.member.userId}'),
                  avatar: Opacity(
                    opacity: .5,
                    child: PersonAvatar(
                      label: nameOrMember(l, m.member.displayName),
                      seed: m.member.userId,
                      avatarPath: m.member.avatarPath,
                      groupSlot: m.colorSlot,
                      radius: 18,
                    ),
                  ),
                  title: nameOrMember(l, m.member.displayName),
                  titleColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  subtitle: m.leftReason == LeftReason.removed
                      ? l.membersRemovedBadge
                      : l.membersLeft,
                ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 26),
              child: Column(
                children: [
                  if (amAdmin)
                    GreyOption(
                      name: 'deladmin',
                      label: AppLocalizations.of(context).groupDeleteForAll,
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onError,
                          ),
                          onPressed: () {},
                          child: Text(
                            AppLocalizations.of(context).groupDeleteForAll,
                          ),
                        ),
                      ),
                    ),
                  if (amAdmin) const SizedBox(height: 10),
                  Builder(
                    builder: (button) => SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        key: const ValueKey('leave-group'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        onPressed: () => _leave(button, ref),
                        child: Text(AppLocalizations.of(context).groupLeave),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A compact row: avatar, name (and a muted second line), optional trailing.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.avatar,
    required this.title,
    this.subtitle = '',
    this.titleColor,
    this.trailing,
    this.onTap,
  });

  final Widget avatar;
  final String title;
  final String subtitle;
  final Color? titleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final text = Theme.of(context).textTheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: SisTokens.settingsRowPadding,
            child: Row(
              children: [
                avatar,
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: text.bodyLarge?.copyWith(color: titleColor),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: text.bodyMedium?.copyWith(color: t.muted),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
