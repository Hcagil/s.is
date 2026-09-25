import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/domain/notification_settings.dart';
import '../../notifications/presentation/notification_pages.dart';
import '../../presence/application/presence_controllers.dart';
import '../../presence/domain/last_seen.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import 'conversation_list.dart';
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
    this.showMessage = true,
  });

  final String userId;

  /// Shown until (or if never) the member list names them.
  final String? fallbackName;

  /// Off when the page was opened from your chat with them: you are there.
  final bool showMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final member = (ref.watch(membersProvider).value ?? const <Member>[])
        .where((m) => m.userId == userId)
        .firstOrNull;
    final name = member?.displayName ?? fallbackName ?? 'Member';
    // Your 1:1 with them, if one exists. The page never creates one just to
    // look; the Message button does.
    final direct = (ref.watch(conversationListProvider).value ?? const [])
        .where((c) => !c.isGroup && c.other?.userId == userId)
        .firstOrNull;
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(),
        body: Column(
          children: [
            PersonAvatar(label: name, seed: userId, radius: 48),
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
            // Muting a person silences them in every chat, groups included.
            MuteTile(kind: MuteKind.person, target: userId),
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

/// A group's page: its members, photos and links. View only.
class GroupScreen extends ConsumerWidget {
  const GroupScreen({
    super.key,
    required this.conversationId,
    required this.title,
  });

  final String conversationId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(conversationMembersProvider(conversationId));
    final names = {
      for (final m in members.value ?? const <Member>[])
        m.userId: m.displayName,
    };
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(),
        body: Column(
          children: [
            PersonAvatar(label: title, seed: conversationId, radius: 48),
            const SizedBox(height: 12),
            Text(
              title,
              key: const ValueKey('group-name'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (members.value case final list?)
              Text(
                list.length == 1 ? '1 member' : '${list.length} members',
                key: const ValueKey('group-count'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            MuteTile(kind: MuteKind.conversation, target: conversationId),
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
                  _MembersTab(conversationId),
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
  const _MembersTab(this.conversationId);

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    final online = ref.watch(onlineMembersProvider);
    return _Async(
      ref.watch(conversationMembersProvider(conversationId)),
      empty: 'No members',
      builder: (members) => ListView(
        children: [
          for (final m in members)
            ListTile(
              key: ValueKey('group-member-${m.userId}'),
              leading: PersonAvatar(
                label: m.displayName,
                seed: m.userId,
                online: online.contains(m.userId),
              ),
              title: Text(
                m.userId == me ? '${m.displayName} (you)' : m.displayName,
              ),
              subtitle: m.tag == null ? null : Text('@${m.tag}'),
              // Your own row leads nowhere; everyone else's to their page.
              onTap: m.userId == me
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PersonScreen(
                          userId: m.userId,
                          fallbackName: m.displayName,
                        ),
                      ),
                    ),
            ),
        ],
      ),
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
    AsyncError(:final error) => _Empty(reasonOf(error)),
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
