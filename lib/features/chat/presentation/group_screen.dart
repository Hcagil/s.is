part of 'profile_pages.dart';

/// A group's page: its members, photos and links. Admins may always change or
/// remove its picture; other members only while the group's switch allows it.
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
    final l = AppLocalizations.of(context);
    switch (result) {
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
      case Ok():
        showSisNotice(
          context,
          choice is AvatarRemoved
              ? l.groupPictureRemoved
              : l.groupPictureUpdated,
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
        m.userId: nameOrMember(AppLocalizations.of(context), m.displayName),
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
    listenGroupGone(context, ref, conversationId);
    final amAdmin = ref.watch(amGroupAdminProvider(conversationId));
    final canSetPicture =
        amAdmin ||
        ref.watch(groupSettingsProvider(conversationId)).membersCanSetAvatar;
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
                      if (canSetPicture)
                        AvatarEditBadge(
                          key: const ValueKey('group-avatar-edit'),
                          busy: _busy,
                          onTap: (picture) =>
                              _changeAvatar(avatarPath, picture),
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
                      AppLocalizations.of(context).groupMemberCount(count),
                      key: const ValueKey('group-count'),
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  MuteTile(kind: MuteKind.conversation, target: conversationId),
                  ChatAlertTiles(conversationId: conversationId),
                  _GroupSettings(
                    conversationId: conversationId,
                    amAdmin: amAdmin,
                  ),
                  const SizedBox(height: 12),
                  TabBar(
                    tabs: [
                      Tab(
                        key: const ValueKey('tab-members'),
                        text: AppLocalizations.of(context).groupTabMembers,
                      ),
                      Tab(
                        key: const ValueKey('tab-media'),
                        text: AppLocalizations.of(context).groupTabMedia,
                      ),
                      Tab(
                        key: const ValueKey('tab-links'),
                        text: AppLocalizations.of(context).groupTabLinks,
                      ),
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

/// The group's three switches. An admin flips them (the new value shows at
/// once, and goes back with a plain line if the server refuses); everyone
/// else sees the real values greyed.
class _GroupSettings extends ConsumerWidget {
  const _GroupSettings({required this.conversationId, required this.amAdmin});

  final String conversationId;
  final bool amAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(groupSettingsProvider(conversationId));
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
        _SettingRow(
          name: 'pickswitch',
          title: l.groupPickSwitch,
          on: s.membersCanSetAvatar,
          amAdmin: amAdmin,
          onChanged: (v) => _set(context, ref, membersCanSetAvatar: v),
        ),
        _SettingRow(
          name: 'addsw',
          title: l.groupAddSwitch,
          on: s.membersCanAdd,
          amAdmin: amAdmin,
          onChanged: (v) => _set(context, ref, membersCanAdd: v),
        ),
        _SettingRow(
          name: 'histsw',
          title: l.groupHistSwitch,
          on: s.newMembersSeeHistory,
          amAdmin: amAdmin,
          onChanged: (v) => _set(context, ref, newMembersSeeHistory: v),
        ),
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

  Future<void> _set(
    BuildContext context,
    WidgetRef ref, {
    bool? membersCanSetAvatar,
    bool? membersCanAdd,
    bool? newMembersSeeHistory,
  }) async {
    final result = await ref
        .read(groupControllerProvider)
        .setSettings(
          conversationId,
          membersCanSetAvatar: membersCanSetAvatar,
          membersCanAdd: membersCanAdd,
          newMembersSeeHistory: newMembersSeeHistory,
        );
    if (!context.mounted) return;
    if (result case Err(:final failure)) {
      showSisNotice(context, failure.message, isError: true);
    }
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.name,
    required this.title,
    required this.on,
    required this.amAdmin,
    required this.onChanged,
  });

  final String name;
  final String title;
  final bool on;
  final bool amAdmin;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: SisTokens.settingsRowPadding,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
          ),
          SisSwitch(
            key: ValueKey('setting-$name'),
            value: on,
            onChanged: amAdmin ? onChanged : null,
          ),
        ],
      ),
    );
    if (amAdmin) return row;
    return GreyOption(name: name, label: title, child: row);
  }
}
