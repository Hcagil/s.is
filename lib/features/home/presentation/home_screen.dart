import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../auth/domain/member.dart';
import '../../chat/application/chat_controllers.dart';
import '../../chat/presentation/conversation_list.dart';
import '../../chat/presentation/message_screen.dart';
import '../../notifications/application/push_controller.dart';
import '../../presence/application/presence_controllers.dart';
import '../../profile/presentation/settings_screen.dart';
import '../../update/presentation/update_banner.dart';

/// Home for an allowed member: the update banner, then the conversations.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps this phone on the delivery list for whoever is signed in.
    ref.listen(pushRegistrationProvider, (_, _) {});
    ref.listen(openedFromNotificationProvider, (_, next) {
      if (next case AsyncData(:final value)) {
        unawaited(_openFromNotification(context, ref, value));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const SisBrandRow(),
        actions: [
          IconButton(
            key: const ValueKey('home-settings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
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

/// Opens the conversation a tapped notification is about. The list is read
/// again when it does not have it yet (a chat started while the app was
/// closed); an id that is still unknown is ignored rather than guessed at.
Future<void> _openFromNotification(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final list = ref.read(conversationListProvider.notifier);
  var conversations = await ref.read(conversationListProvider.future);
  if (!conversations.any((c) => c.id == id)) {
    await list.reloadQuietly();
    conversations = ref.read(conversationListProvider).value ?? const [];
  }
  final match = conversations.where((c) => c.id == id).firstOrNull;
  if (match == null || !context.mounted) return;
  await openConversation(
    context,
    ref,
    match.id,
    title: match.label,
    otherUserId: match.other?.userId,
    group: match.isGroup,
  );
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
