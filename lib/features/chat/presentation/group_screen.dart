part of 'profile_pages.dart';

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
        body: NestedScrollView(
          headerSliverBuilder: (_, _) => [
            SliverToBoxAdapter(
              child: Column(
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
                  SizedBox(
                    height: 3,
                    child: _busy ? const SisProgressLine() : null,
                  ),
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
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  MuteTile(kind: MuteKind.conversation, target: conversationId),
                  ChatAlertTiles(conversationId: conversationId),
                  const _GroupSettings(),
                  const SizedBox(height: 12),
                  const TabBar(
                    tabs: [
                      Tab(key: ValueKey('tab-members'), text: 'Members'),
                      Tab(key: ValueKey('tab-media'), text: 'Media'),
                      Tab(key: ValueKey('tab-links'), text: 'Links'),
                    ],
                  ),
                ],
              ),
            ),
          ],
          body: TabBarView(
            children: [
              _MembersTab(conversationId, title: title),
              _MediaTab(conversationId),
              _LinksTab(conversationId, names: names),
            ],
          ),
        ),
      ),
    );
  }
}

/// The group's settings as they are today: any member may change the
/// picture, only admins add people, and whether a new member sees earlier
/// messages is chosen per addition. Greyed (not changeable) until the real
/// settings arrive.
class _GroupSettings extends StatelessWidget {
  const _GroupSettings();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            l.groupSettingsTitle,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: t.muted,
              fontWeight: SisTokens.sectionLabelWeight,
            ),
          ),
        ),
        _GreySwitchRow(name: 'pickswitch', title: l.groupPickSwitch, on: true),
        _GreySwitchRow(name: 'addsw', title: l.groupAddSwitch, on: false),
        _GreySwitchRow(name: 'histsw', title: l.groupHistSwitch, on: false),
        GreyOption(
          name: 'p_who',
          label: l.groupPinWho,
          child: SisSettingsRow(
            icon: Icons.push_pin_outlined,
            title: l.groupPinWho,
          ),
        ),
      ],
    );
  }
}

class _GreySwitchRow extends StatelessWidget {
  const _GreySwitchRow({
    required this.name,
    required this.title,
    required this.on,
  });

  final String name;
  final String title;
  final bool on;

  @override
  Widget build(BuildContext context) => GreyOption(
    name: name,
    label: title,
    child: Padding(
      padding: SisTokens.settingsRowPadding,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
          ),
          Switch(value: on, onChanged: null),
        ],
      ),
    ),
  );
}
