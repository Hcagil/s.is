import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../chat/presentation/conversation_list.dart';
import '../../profile/application/profile_controller.dart';
import '../../profile/presentation/settings_screen.dart';
import '../../update/presentation/update_banner.dart';

/// Home for an allowed member: the update banner, then the conversations.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The profile, not the session, so a rename in settings shows here at
    // once.
    final name =
        ref.watch(ownProfileProvider).value?.displayName ?? member.displayName;
    return Scaffold(
      appBar: AppBar(
        title: const SisBrandRow(),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('home-menu'),
            onSelected: (choice) => switch (choice) {
              'settings' => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              _ => ref.read(sessionControllerProvider.notifier).signOut(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                key: ValueKey('menu-settings'),
                value: 'settings',
                child: Text('Settings'),
              ),
              PopupMenuItem(
                key: const ValueKey('menu-sign-out'),
                value: 'sign-out',
                child: Text('Sign out ($name)'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: const [
            UpdateBanner(),
            Expanded(child: ConversationList()),
          ],
        ),
      ),
    );
  }
}
