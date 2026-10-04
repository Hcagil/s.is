import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/domain/notification_settings.dart';
import '../../notifications/presentation/alert_widgets.dart';
import '../../notifications/presentation/notification_pages.dart';
import '../../presence/application/presence_controllers.dart';
import '../../presence/domain/last_seen.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import '../domain/group_member.dart';
import '../domain/message.dart';
import 'add_members_page.dart';
import 'avatar_card.dart';
import 'message_screen.dart';
import 'person_avatar.dart';
import 'photo_viewer.dart';

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
    final name = member?.displayName ?? fallbackName ?? 'Member';
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
            if (showMessage) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('person-message'),
                onPressed: () => _message(context, ref, name, direct?.id),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: const Text('Message'),
              ),
            ],
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
    return OutlinedButton.icon(
      key: const ValueKey('person-contact-toggle'),
      onPressed: () async {
        final notifier = ref.read(contactsControllerProvider.notifier);
        final result = isContact
            ? await notifier.remove(userId)
            : await notifier.add(userId);
        if (result case Err(:final failure) when context.mounted) {
          showSisNotice(context, failure.message, isError: true);
        }
      },
      icon: Icon(
        isContact
            ? Icons.person_remove_outlined
            : Icons.person_add_alt_1_outlined,
      ),
      label: Text(isContact ? 'Remove from contacts' : 'Add to contacts'),
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
    final text = online
        ? 'online'
        : at == null
        ? null
        : lastSeenLabel(at, DateTime.now());
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

/// A group's page: its members, photos and links. Any member may change or
/// remove its picture, the same as a member-editable group name would be.
class GroupScreen extends ConsumerStatefulWidget {
  const GroupScreen({
    super.key,
    required this.conversationId,
    required this.title,
  });

  final String conversationId;
  final String title;

  @override
  ConsumerState<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends ConsumerState<GroupScreen> {
  bool _busy = false;

  Future<void> _changeAvatar(String? avatarPath, Rect picture) async {
    final choice = await showAvatarCard(
      context,
      ref,
      anchor: picture,
      hasAvatar: avatarPath != null,
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    final result = await ref
        .read(conversationListProvider.notifier)
        .setGroupAvatar(widget.conversationId, switch (choice) {
          AvatarPicked(:final image) => image,
          AvatarRemoved() => null,
        });
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
      case Ok():
        showSisNotice(
          context,
          choice is AvatarRemoved
              ? 'Group picture removed'
              : 'Group picture updated',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationId = widget.conversationId;
    final title = widget.title;
    final members = ref.watch(conversationMembersProvider(conversationId));
    final names = {
      for (final m in members.value ?? const <Member>[])
        m.userId: m.displayName,
    };
    // Current members only -- a departed member still has a row (was_member
    // keeps their history readable), but does not belong in "N members".
    final currentCount = ref
        .watch(groupRosterProvider(conversationId))
        .value
        ?.where((m) => !m.hasLeft)
        .length;
    final avatarPath = (ref.watch(conversationListProvider).value ?? const [])
        .where((c) => c.id == conversationId)
        .firstOrNull
        ?.avatarPath;
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(),
        body: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                GestureDetector(
                  key: const ValueKey('group-avatar'),
                  onTap: avatarPath == null
                      ? null
                      : () => openPhotoViewer(
                          context,
                          [avatarPath],
                          0,
                          isAvatar: true,
                        ),
                  child: PersonAvatar(
                    label: title,
                    seed: conversationId,
                    radius: 48,
                    avatarPath: avatarPath,
                  ),
                ),
                AvatarEditBadge(
                  key: const ValueKey('group-avatar-edit'),
                  busy: _busy,
                  onTap: (picture) => _changeAvatar(avatarPath, picture),
                ),
              ],
            ),
            SizedBox(height: 3, child: _busy ? const SisProgressLine() : null),
            const SizedBox(height: 12),
            Text(
              title,
              key: const ValueKey('group-name'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (currentCount case final count?)
              Text(
                count == 1 ? '1 member' : '$count members',
                key: const ValueKey('group-count'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            MuteTile(kind: MuteKind.conversation, target: conversationId),
            ChatAlertTiles(conversationId: conversationId),
            const SizedBox(height: 12),
            const TabBar(
              tabs: [
                Tab(key: ValueKey('tab-members'), text: 'Members'),
                Tab(key: ValueKey('tab-media'), text: 'Media'),
                Tab(key: ValueKey('tab-links'), text: 'Links'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _MembersTab(conversationId, title: title),
                  _MediaTab(conversationId),
                  _LinksTab(conversationId, names: names),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

/// A photo grid, newest first; a tap opens the viewer at that photo.
class _MediaTab extends ConsumerWidget {
  const _MediaTab(this.conversationId);

  /// Null when there is no conversation to show photos from.
  final String? conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const empty = 'No photos shared yet';
    final id = conversationId;
    if (id == null) return const _Empty(empty);
    return _Async(
      ref.watch(sharedMediaProvider(id)),
      empty: empty,
      builder: (photos) {
        final paths = [for (final m in photos) m.attachmentPath!];
        return GridView.builder(
          key: const ValueKey('media-grid'),
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: paths.length,
          itemBuilder: (context, i) => GestureDetector(
            key: ValueKey('media-${paths[i]}'),
            onTap: () => openPhotoViewer(context, paths, i),
            child: _Thumb(paths[i]),
          ),
        );
      },
    );
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb(this.path);

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
    );
    return switch (ref.watch(attachmentBytesProvider(path))) {
      // Decoded at thumbnail size: a grid of full photos would hold every one
      // at full resolution in memory.
      AsyncData(:final value) => Image.memory(
        value,
        cacheWidth: 300,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
      _ => placeholder,
    };
  }
}

/// Links, newest first: the site, the address, who sent it and when.
class _LinksTab extends ConsumerWidget {
  const _LinksTab(this.conversationId, {required this.names});

  final String? conversationId;

  /// Display names by user id, for "who sent it"; the caller is "You".
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const empty = 'No links shared yet';
    final id = conversationId;
    if (id == null) return const _Empty(empty);
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    return _Async(
      ref.watch(sharedLinksProvider(id)),
      empty: empty,
      builder: (links) => ListView(
        children: [
          for (final (i, entry) in links.indexed)
            ListTile(
              key: ValueKey('link-$i'),
              leading: const Icon(Icons.link_rounded),
              title: Text(entry.link.host),
              subtitle: Text(
                '${entry.link}\n'
                '${entry.message.senderId == me ? 'You' : names[entry.message.senderId] ?? 'Member'}'
                ' · ${previewTime(entry.message.createdAt, DateTime.now())}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: true,
              onTap: () async {
                final opened = await ref
                    .read(linkOpenerProvider)
                    .open(entry.link);
                if (!opened && context.mounted) {
                  showSisNotice(
                    context,
                    'Could not open ${entry.link.host}',
                    isError: true,
                  );
                }
              },
            ),
        ],
      ),
    );
  }
}

/// Loading, failure with its reason, empty, or the list.
class _Async<T> extends StatelessWidget {
  const _Async(this.value, {required this.empty, required this.builder});

  final AsyncValue<List<T>> value;
  final String empty;
  final Widget Function(List<T>) builder;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncData(:final value) when value.isEmpty => _Empty(empty),
    AsyncData(:final value) => builder(value),
    AsyncError(:final error) => _Empty(failureReason(error)),
    _ => const Center(child: SisLoadingLogo(size: 40)),
  };
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

/// The SIS chat's profile page: only mute, since it cannot be left or
/// written into.
class SystemChatScreen extends StatelessWidget {
  const SystemChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          PersonAvatar(label: 'SIS', seed: conversationId, radius: 48),
          const SizedBox(height: 12),
          Text(
            'SIS',
            key: const ValueKey('system-name'),
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            "What's new in the app",
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          MuteTile(kind: MuteKind.conversation, target: conversationId),
        ],
      ),
    );
  }
}
