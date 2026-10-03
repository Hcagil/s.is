import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../../app/controls.dart';
import '../../../app/licences_page.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../../chat/presentation/avatar_card.dart';
import '../../chat/presentation/person_avatar.dart';
import '../../chat/presentation/photo_viewer.dart';
import '../../notifications/application/push_controller.dart';
import '../../notifications/presentation/notification_pages.dart';
import '../../presence/application/presence_controllers.dart';
import '../../update/application/update_controller.dart';
import '../application/profile_controller.dart';
import '../domain/own_profile.dart';
import 'profile_form.dart';

Future<void> _setSharing(
  BuildContext context,
  WidgetRef ref, {
  bool? presence,
  bool? typing,
  bool? lastSeen,
  bool? readStatus,
}) async {
  final result = await ref
      .read(ownProfileProvider.notifier)
      .setSharing(
        presence: presence,
        typing: typing,
        lastSeen: lastSeen,
        readStatus: readStatus,
      );
  // Turning last seen back on starts from now, not from nothing: the server
  // forgot the old time when it was turned off.
  if (result is Ok && lastSeen == true) {
    await ref.read(lastSeenReporterProvider)();
  }
  if (result case Err(:final failure) when context.mounted) {
    showSisNotice(context, failure.message, isError: true);
  }
}

Future<void> _setAvatarVisibility(
  BuildContext context,
  WidgetRef ref,
  AvatarVisibility value,
) async {
  final result = await ref
      .read(ownProfileProvider.notifier)
      .setAvatarVisibility(value);
  if (result case Err(:final failure) when context.mounted) {
    showSisNotice(context, failure.message, isError: true);
  }
}

void _open(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

/// The profile, or its loading and failure states, for every settings page.
class _WithProfile extends ConsumerWidget {
  const _WithProfile({required this.title, required this.builder});

  final String title;
  final Widget Function(BuildContext context, OwnProfile profile) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: switch (ref.watch(ownProfileProvider)) {
          AsyncData(:final value) => builder(context, value),
          AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    error is Failure ? error.message : '$error',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(ownProfileProvider.notifier).retry(),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
          _ => const Center(child: SisLoadingLogo()),
        },
      ),
    );
  }
}

/// Settings: the member's profile card, then one row per section.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    ListTile row(String key, IconData icon, String title, Widget page) =>
        ListTile(
          key: ValueKey(key),
          leading: Icon(icon),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _open(context, page),
        );
    return _WithProfile(
      title: 'Settings',
      builder: (context, profile) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            key: const ValueKey('settings-profile'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: PersonAvatar(
              label: profile.displayName,
              seed: profile.userId,
              radius: 28,
              avatarPath: profile.avatarPath,
            ),
            title: Text(
              profile.displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text('@${profile.tag}'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open(context, const ProfileSettingsScreen()),
          ),
          const Divider(),
          row(
            'settings-privacy',
            Icons.lock_outline_rounded,
            'Privacy',
            const PrivacyScreen(),
          ),
          row(
            'settings-notifications',
            Icons.notifications_outlined,
            'Notifications',
            const NotificationsScreen(),
          ),
          row(
            'settings-account',
            Icons.account_circle_outlined,
            'Account',
            const AccountScreen(),
          ),
          row(
            'settings-about',
            Icons.info_outline_rounded,
            'About',
            const AboutScreen(),
          ),
        ],
      ),
    );
  }
}

/// Display name and tag.
class ProfileSettingsScreen extends ConsumerStatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  ConsumerState<ProfileSettingsScreen> createState() =>
      _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends ConsumerState<ProfileSettingsScreen> {
  bool _busy = false;

  Future<void> _changeAvatar(OwnProfile profile, Rect picture) async {
    final choice = await showAvatarCard(
      context,
      ref,
      anchor: picture,
      hasAvatar: profile.avatarPath != null,
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    final result = switch (choice) {
      AvatarPicked(:final image) =>
        await ref.read(ownProfileProvider.notifier).setAvatar(image),
      AvatarRemoved() =>
        await ref.read(ownProfileProvider.notifier).removeAvatar(),
    };
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
      case Ok():
        showSisNotice(
          context,
          choice is AvatarRemoved
              ? 'Profile picture removed'
              : 'Profile picture updated',
        );
    }
  }

  @override
  Widget build(BuildContext context) => _WithProfile(
    title: 'Profile',
    builder: (context, profile) => ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              GestureDetector(
                key: const ValueKey('profile-avatar'),
                onTap: profile.avatarPath == null
                    ? null
                    : () => openPhotoViewer(
                        context,
                        [profile.avatarPath!],
                        0,
                        isAvatar: true,
                      ),
                child: PersonAvatar(
                  label: profile.displayName,
                  seed: profile.userId,
                  radius: 48,
                  avatarPath: profile.avatarPath,
                ),
              ),
              AvatarEditBadge(
                key: const ValueKey('profile-avatar-edit'),
                busy: _busy,
                onTap: (picture) => _changeAvatar(profile, picture),
              ),
            ],
          ),
        ),
        SizedBox(height: 3, child: _busy ? const SisProgressLine() : null),
        const SizedBox(height: 20),
        ProfileForm(
          // Rebuilt from the saved profile, so the fields show what is
          // stored rather than what was typed.
          key: ValueKey('${profile.displayName}|${profile.tag}'),
          profile: profile,
          submitLabel: 'Save',
          onSubmit: (name, tag) async {
            final result = await ref
                .read(ownProfileProvider.notifier)
                .save(displayName: name, tag: tag);
            if (result is Ok && context.mounted) {
              showSisNotice(context, 'Saved');
            }
            return result;
          },
        ),
      ],
    ),
  );
}

/// What others can see.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _WithProfile(
    title: 'Privacy',
    builder: (context, profile) => ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        SisSwitchTile(
          key: const ValueKey('share-presence'),
          title: 'Show when I am online',
          value: profile.sharePresence,
          onChanged: (on) => _setSharing(context, ref, presence: on),
        ),
        SisSwitchTile(
          key: const ValueKey('share-typing'),
          title: 'Show when I am typing',
          value: profile.shareTyping,
          onChanged: (on) => _setSharing(context, ref, typing: on),
        ),
        SisSwitchTile(
          key: const ValueKey('share-last-seen'),
          title: 'Show my last seen',
          subtitle: "While this is off, you can't see anyone else's either.",
          value: profile.shareLastSeen,
          onChanged: (on) => _setSharing(context, ref, lastSeen: on),
        ),
        SisSwitchTile(
          key: const ValueKey('share-read-status'),
          title: 'Show when I have read messages',
          subtitle: "While this is off, you can't see when others read yours.",
          value: profile.shareReadStatus,
          onChanged: (on) => _setSharing(context, ref, readStatus: on),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Profile picture visibility',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        const SizedBox(height: 4),
        Column(
          children: [
            for (final v in AvatarVisibility.values)
              SisChoiceCard<AvatarVisibility>(
                key: ValueKey('avatar-visibility-${v.name}'),
                value: v,
                groupValue: profile.avatarVisibility,
                onChanged: (v) => _setAvatarVisibility(context, ref, v),
                title: switch (v) {
                  AvatarVisibility.everyone => 'Everyone',
                  AvatarVisibility.contacts => 'My contacts',
                  AvatarVisibility.nobody => 'Nobody',
                },
                subtitle: switch (v) {
                  AvatarVisibility.everyone =>
                    'Anyone who can see your profile',
                  AvatarVisibility.contacts => 'Only people you have saved',
                  AvatarVisibility.nobody =>
                    "Only you -- others see your initials",
                },
              ),
          ],
        ),
      ],
    ),
  );
}

/// The Google account in use, and signing out.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final email = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.email,
      _ => null,
    };
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Signed in with Google as', style: TextStyle(color: muted)),
            const SizedBox(height: 4),
            Text(
              email ?? 'Unknown account',
              key: const ValueKey('account-email'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              key: const ValueKey('account-sign-out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () async {
                // Read before leaving: this page is gone after the pop.
                final push = ref.read(pushRegistrationProvider.notifier);
                final session = ref.read(sessionControllerProvider.notifier);
                // Back to the root first: signing out swaps the root screen,
                // and the settings pages above it would otherwise stay.
                Navigator.of(context).popUntil((route) => route.isFirst);
                // While still signed in: this phone stops receiving this
                // account's notifications.
                await push.forget();
                // The next account on this phone must not inherit the last
                // one's photos: attachmentCacheOwnerProvider clears them as
                // soon as this reaches SignedOut, on this path exactly as on
                // any other the session can end on.
                await session.signOut();
              },
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Version, build and licences.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(installedVersionProvider).value;
    final label = version == null
        ? ''
        : 'Version ${version.name} (${version.build})';
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Row(
              children: [
                SisLogo(size: 56),
                SizedBox(width: 16),
                SisWordmark(size: 40),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Stay in sync',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              key: const ValueKey('about-version'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            ListTile(
              key: const ValueKey('about-licences'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: const Text('Open-source licences'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SisLicencesPage(
                    applicationName: 'SIS',
                    applicationVersion: label,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
