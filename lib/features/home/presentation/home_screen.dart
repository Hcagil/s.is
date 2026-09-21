import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../update/presentation/update_banner.dart';

/// Home for an allowed member; the update banner sits above the content.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('SIS')),
      body: SafeArea(
        child: Column(
          children: [
            const UpdateBanner(),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Welcome back, ${member.displayName}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton(
                      onPressed: () => ref
                          .read(sessionControllerProvider.notifier)
                          .signOut(),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
