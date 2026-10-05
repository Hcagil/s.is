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
        showSisNotice(context, '${m.member.displayName} removed');
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
        showSisNotice(
          context,
          isAdmin
              ? '${m.member.displayName} is now an admin'
              : '${m.member.displayName} is no longer an admin',
        );
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text(
          'You can still see the messages up to now, but you will not '
          'receive anything new.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('leave-cancel'),
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('leave-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialog).colorScheme.error,
              foregroundColor: Theme.of(dialog).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Leave'),
          ),
        ],
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
              ? "Left the group. Unsent messages weren't sent."
              : 'Left the group',
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
    return _Async(
      ref.watch(groupRosterProvider(conversationId)),
      empty: 'No members',
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
              ListTile(
                key: const ValueKey('add-members'),
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: const Text('Add members'),
                onTap: () => showAddMembersPage(
                  context,
                  ref,
                  conversationId,
                  current: {for (final m in current) m.member.userId},
                  groupTitle: title,
                ),
              ),
            for (final m in current)
              ListTile(
                key: ValueKey('group-member-${m.member.userId}'),
                leading: PersonAvatar(
                  label: m.member.displayName,
                  seed: m.member.userId,
                  online: online.contains(m.member.userId),
                  avatarPath: m.member.avatarPath,
                  groupSlot: m.colorSlot,
                ),
                title: Text(
                  m.member.userId == me
                      ? '${m.member.displayName} (you)'
                      : m.member.displayName,
                ),
                subtitle: Text(
                  [
                    if (m.isAdmin) 'Admin',
                    if (m.member.tag != null) '@${m.member.tag}',
                  ].join(' · '),
                ),
                trailing: amAdmin && m.member.userId != me
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('toggle-admin-${m.member.userId}'),
                            icon: Icon(
                              m.isAdmin
                                  ? Icons.remove_moderator_outlined
                                  : Icons.admin_panel_settings_outlined,
                            ),
                            tooltip: m.isAdmin
                                ? 'Remove as admin'
                                : 'Make admin',
                            onPressed: () =>
                                _setAdmin(context, ref, m, !m.isAdmin),
                          ),
                          IconButton(
                            key: ValueKey('remove-member-${m.member.userId}'),
                            icon: const Icon(Icons.person_remove_outlined),
                            tooltip: 'Remove',
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
                            fallbackName: m.member.displayName,
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
                  'Left',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final m in departed)
                ListTile(
                  key: ValueKey('group-member-${m.member.userId}'),
                  leading: Opacity(
                    opacity: .5,
                    child: PersonAvatar(
                      label: m.member.displayName,
                      seed: m.member.userId,
                      avatarPath: m.member.avatarPath,
                      groupSlot: m.colorSlot,
                    ),
                  ),
                  title: Text(
                    m.member.displayName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  subtitle: Text(
                    m.leftReason == LeftReason.removed ? 'Removed' : 'Left',
                  ),
                ),
            ],
            const Divider(),
            ListTile(
              key: const ValueKey('leave-group'),
              leading: Icon(
                Icons.logout,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Leave group',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => _leave(context, ref),
            ),
          ],
        );
      },
    );
  }
}
