part of 'profile_pages.dart';

/// Links, newest first: the site, the address, who sent it and when.
class _LinksTab extends ConsumerWidget {
  const _LinksTab(this.conversationId, {required this.names});

  final String? conversationId;

  /// Display names by user id, for "who sent it"; the caller is "You".
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final empty = l.linksEmpty;
    final id = conversationId;
    if (id == null) return _Empty(empty);
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
                '${entry.message.senderId == me ? l.commonYou : names[entry.message.senderId] ?? l.commonMember}'
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
                    l.linkOpenFailed(entry.link.host),
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
