import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../chat/presentation/conversation_list.dart';
import '../../update/presentation/update_banner.dart';

/// Home for an allowed member: the update banner, then the conversations.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SIS'),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('home-menu'),
            onSelected: (_) =>
                ref.read(sessionControllerProvider.notifier).signOut(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'sign-out',
                child: Text('Sign out (${member.displayName})'),
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
