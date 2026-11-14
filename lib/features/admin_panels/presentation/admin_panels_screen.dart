import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';
import '../application/admin_panels_state.dart';
import 'admin_dashboard_view.dart';
import 'admin_link_view.dart';
import 'admin_questions_view.dart';
import 'admin_talk_view.dart';
import 'admin_tasks_view.dart';

Future<void> showAdminPanels(BuildContext context) => Navigator.of(context)
    .push<void>(MaterialPageRoute(builder: (_) => const AdminPanelsScreen()));

class AdminPanelsScreen extends ConsumerStatefulWidget {
  const AdminPanelsScreen({super.key});

  @override
  ConsumerState<AdminPanelsScreen> createState() => _AdminPanelsScreenState();
}

class _AdminPanelsScreenState extends ConsumerState<AdminPanelsScreen>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final n = ref.read(adminPanelsProvider.notifier);
      n.setForeground(true);
      n.open(AppLocalizations.of(context).adminUnlockReason);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final n = ref.read(adminPanelsProvider.notifier);
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      // Background: lock; the unlock is asked again on return.
      if (n.lock()) _locked = true;
    } else if (s == AppLifecycleState.resumed) {
      n.setForeground(true);
      if (_locked) {
        _locked = false;
        n.open(AppLocalizations.of(context).adminUnlockReason);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final panels = ref.watch(adminPanelsProvider);
    final gate = panels.gate;
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);

    const tabs = [null, 'talk', 'questions', 'tasks'];
    final openTab = tabs[_index];
    final counts = panels.newCounts;
    if (gate == AdminGate.ready &&
        openTab != null &&
        (counts[openTab] ?? 0) > 0) {
      // The tab that is open shows no number: what it holds is seen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(adminPanelsProvider.notifier).markSeen(openTab);
      });
    }

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Text(l.adminTitle),
        actions: [if (gate == AdminGate.ready) _ConnIcon(panels.conn, t.muted)],
      ),
      body: SafeArea(
        child: switch (gate) {
          AdminGate.checking => const Align(
            alignment: Alignment.topCenter,
            child: SisProgressLine(),
          ),
          AdminGate.cancelled => _Message(
            text: l.adminUnlockCancelled,
            buttonLabel: l.adminUnlockRetry,
            onPressed: _reopen,
          ),
          AdminGate.noLock => _Message(text: l.adminUnlockNoLock),
          AdminGate.notOwner => const SizedBox.shrink(),
          AdminGate.link => const AdminLinkView(),
          AdminGate.failed => _Message(
            text: l.adminLoadFailed,
            buttonLabel: l.adminRetry,
            onPressed: _reopen,
          ),
          AdminGate.ready => switch (_index) {
            1 => const AdminTalkView(key: ValueKey('admin-panel-0')),
            2 => const AdminQuestionsView(key: ValueKey('admin-panel-1')),
            3 => const AdminTasksView(key: ValueKey('admin-panel-2')),
            _ => const AdminDashboardView(key: ValueKey('admin-panel-3')),
          },
        },
      ),
      bottomNavigationBar: gate == AdminGate.ready
          ? NavigationBar(
              key: const ValueKey('admin-bottom-bar'),
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              backgroundColor: t.surface,
              indicatorColor: t.surfaceHigh,
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.dashboard_outlined),
                  selectedIcon: const Icon(Icons.dashboard_rounded),
                  label: l.adminDashboard,
                ),
                NavigationDestination(
                  icon: _badged(
                    const Icon(Icons.chat_bubble_outline_rounded),
                    openTab == 'talk' ? 0 : counts['talk'] ?? 0,
                  ),
                  selectedIcon: const Icon(Icons.chat_bubble_rounded),
                  label: l.adminTalk,
                ),
                NavigationDestination(
                  icon: _badged(
                    const Icon(Icons.help_outline_rounded),
                    openTab == 'questions' ? 0 : counts['questions'] ?? 0,
                  ),
                  selectedIcon: const Icon(Icons.help_rounded),
                  label: l.adminQuestions,
                ),
                NavigationDestination(
                  icon: _badged(
                    const Icon(Icons.checklist_rounded),
                    openTab == 'tasks' ? 0 : counts['tasks'] ?? 0,
                  ),
                  selectedIcon: const Icon(Icons.checklist_rounded),
                  label: l.adminTasks,
                ),
              ],
            )
          : null,
    );
  }

  void _reopen() => ref
      .read(adminPanelsProvider.notifier)
      .open(AppLocalizations.of(context).adminUnlockReason);
}

/// The icon with the number of new items on it; no badge at 0.
Widget _badged(Widget icon, int n) =>
    n == 0 ? icon : Badge(label: Text('$n'), child: icon);

class _Message extends StatelessWidget {
  const _Message({required this.text, this.buttonLabel, this.onPressed});

  final String text;
  final String? buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.muted),
            ),
            if (buttonLabel != null) ...[
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('admin-message-button'),
                onPressed: onPressed,
                child: Text(buttonLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The connection icon in the top bar: exactly one state at a time.
class _ConnIcon extends StatelessWidget {
  const _ConnIcon(this.conn, this.mutedColor);

  final AdminConn conn;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final (key, icon, color, label) = switch (conn) {
      AdminConn.connected => (
        'connected',
        Icons.cloud_done_rounded,
        Colors.green,
        l.adminConnConnected,
      ),
      AdminConn.connecting => (
        'connecting',
        Icons.cloud_sync_rounded,
        Colors.orange,
        l.adminConnConnecting,
      ),
      AdminConn.offline => (
        'offline',
        Icons.cloud_off_rounded,
        mutedColor,
        l.adminConnOffline,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Icon(icon, key: ValueKey('admin-conn-$key'), color: color),
      ),
    );
  }
}
