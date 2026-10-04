import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../auth/domain/member.dart';
import '../../auth/presentation/session_check_notice.dart';
import '../../chat/application/chat_controllers.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/presentation/conversation_list.dart';
import '../../chat/presentation/message_screen.dart';
import '../../notifications/application/push_controller.dart';
import '../../presence/application/presence_controllers.dart';
import '../../profile/presentation/settings_screen.dart';
import '../../update/presentation/update_banner.dart';

/// Home for an allowed member: the update banner, then the conversations.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.member});

  final Member member;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  StreamSubscription<String>? _taps;

  @override
  void initState() {
    super.initState();
    _taps = ref.read(notificationTapsProvider).listen((id) {
      if (mounted) unawaited(_openFromNotification(context, ref, id));
    });
  }

  @override
  void dispose() {
    unawaited(_taps?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              SessionCheckNotice(),
              UpdateBanner(),
              Expanded(child: ConversationList()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the conversation a tapped notification is about, at once, with no
/// network wait; see below for a chat the list does not hold yet.
Future<void> _openFromNotification(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  // Already on screen: opening it again would stack a second copy; the same
  // catch-up as coming back to the app instead.
  if (ref.read(openConversationProvider) == id) {
    ref.read(resumeCatchUpProvider)();
    return;
  }
  // No waiting: the chat is pushed in this very frame with what the list
  // holds right now (the stored snapshot counts). A chat the list does not
  // know yet opens with its header empty -- MessageScreen fills title, group
  // and the other member in from the list once it has them -- and is dropped
  // again below if the list never learns it.
  final match = _listed(ref, id);
  // Back from this chat must reach the list, not a chat that was open
  // before: close that one first (so it is not recorded as `previous`),
  // then drop everything above the list.
  ref.read(openConversationProvider.notifier).close();
  Navigator.of(context).popUntil((route) => route.isFirst);
  final opened = openConversation(
    context,
    ref,
    id,
    title: match?.label,
    otherUserId: match?.other?.userId,
    group: match?.isGroup ?? false,
  );
  if (match == null) unawaited(_dropIfUnknown(context, ref, id));
  await opened;
}

Conversation? _listed(WidgetRef ref, String id) =>
    (ref.read(conversationListProvider).value ?? const <Conversation>[])
        .where((c) => c.id == id)
        .firstOrNull;

/// The list is read again when it does not have [id] once it has settled (a
/// chat started while the app was closed); an id that is still unknown after
/// that is not a chat this member can open, so its screen is closed again
/// rather than left empty.
Future<void> _dropIfUnknown(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final settled = Completer<void>();
  final sub = ref.listenManual(conversationListProvider, (_, next) {
    if (!next.isLoading && !settled.isCompleted) settled.complete();
  }, fireImmediately: true);
  await settled.future;
  sub.close();
  if (_listed(ref, id) == null) {
    await ref.read(conversationListProvider.notifier).reloadQuietly();
  }
  if (_listed(ref, id) != null) return;
  if (!context.mounted || ref.read(openConversationProvider) != id) return;
  Navigator.of(context).pop();
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
