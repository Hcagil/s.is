import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../chat/presentation/conversation_list.dart';
import '../../presence/application/presence_controllers.dart';
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
      body: _ReportsLastSeen(
        child: SafeArea(
          child: Column(
            children: const [
              UpdateBanner(),
              Expanded(child: ConversationList()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reports "seen now" when the signed-in app opens, comes back to the
/// foreground and leaves it. Lives on the home screen because that is what an
/// allowed, signed-in member is looking at.
class _ReportsLastSeen extends ConsumerStatefulWidget {
  const _ReportsLastSeen({required this.child});

  final Widget child;

  @override
  ConsumerState<_ReportsLastSeen> createState() => _ReportsLastSeenState();
}

class _ReportsLastSeenState extends ConsumerState<_ReportsLastSeen> {
  late final AppLifecycleListener _lifecycle;

  void _report() => ref.read(lastSeenReporterProvider)();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _report, onHide: _report);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _report();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
