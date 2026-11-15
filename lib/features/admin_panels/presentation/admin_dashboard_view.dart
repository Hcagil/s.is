import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/loading.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';
import '../domain/admin_dashboard.dart';
import 'admin_work_colors.dart';
import 'admin_work_row.dart';

class AdminDashboardView extends ConsumerWidget {
  const AdminDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(adminPanelsProvider);
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    if (!s.hasSnapshot) {
      return const Align(
        alignment: Alignment.topCenter,
        child: SisProgressLine(),
      );
    }

    final d = s.snapshot.dashboard;
    if (d != null && d.stale) {
      return Center(
        child: Text(
          l.adminDashboardStale,
          key: const ValueKey('admin-dash-stale'),
          textAlign: TextAlign.center,
          style: TextStyle(color: t.muted),
        ),
      );
    }
    if (d == null ||
        (d.working.isEmpty && d.sessions.isEmpty && d.usage.isEmpty)) {
      return Center(child: Text(l.adminDashEmpty));
    }

    final families = adminWorkFamilies(d.working);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (d.working.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
            child: Text(
              l.adminDashWorking,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (var i = 0; i < d.working.length; i++)
            AdminWorkRow(
              key: ValueKey('admin-dash-work-$i'),
              entry: d.working[i],
              entries: d.working,
              family: families[i],
            ),
        ],
        if (d.usage.any((u) => _usageKinds.contains(u.kind))) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
            child: Text(
              l.adminDashUsage,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final u in d.usage.where((u) => _usageKinds.contains(u.kind)))
            Semantics(
              label: _usageA11y(l, u),
              excludeSemantics: true,
              child: SisSettingsRow(
                key: ValueKey('admin-dash-usage-${u.kind}'),
                icon: Icons.speed_outlined,
                title: _usageTitle(l, u.kind),
                showArrow: false,
                subtitle: _usageLine(l, u),
                iconColor: u.percentUsed >= 90 ? t.danger : null,
              ),
            ),
        ],
        if (d.sessions.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
            child: Text(
              l.adminDashContext,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final session in d.sessions)
            SisSettingsRow(
              key: ValueKey('admin-dash-ctx-${session.name}'),
              icon: Icons.insights_outlined,
              title: session.name,
              showArrow: false,
              subtitle: session.contextK == null
                  ? null
                  : '${session.contextK!.round()}k',
              iconColor: (session.contextK != null && session.contextK! >= 230)
                  ? t.danger
                  : null,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
            child: Text(
              l.adminDashTasksLeft,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final session in d.sessions)
            if (session.counts.isNotEmpty ||
                session.rows.isNotEmpty ||
                session.todo.isNotEmpty)
              _TasksLeftTile(session: session),
        ],
      ],
    );
  }
}

const _usageKinds = {'five_hour', 'seven_day', 'spend_limit'};

String _usageTitle(AppLocalizations l, String kind) => switch (kind) {
  'five_hour' => l.adminDashUsageSession,
  'seven_day' => l.adminDashUsageWeek,
  _ => l.adminDashUsageSpend,
};

String _usageTime(AppLocalizations l, AdminRateLimit u) {
  final at = DateTime.tryParse(u.resetsAt ?? '')?.toLocal();
  if (at == null) return '-';
  return switch (u.kind) {
    'five_hour' => DateFormat.Hm(l.localeName).format(at),
    _ => DateFormat.MMMd(l.localeName).format(at),
  };
}

String _usageLine(AppLocalizations l, AdminRateLimit u) =>
    l.adminDashUsageLine(u.percentUsed, _usageTime(l, u));

String _usageA11y(AppLocalizations l, AdminRateLimit u) {
  final p = u.percentUsed;
  final t = _usageTime(l, u);
  return switch (u.kind) {
    'five_hour' => l.adminDashUsageSessionA11y(p, t),
    'seven_day' => l.adminDashUsageWeekA11y(p, t),
    _ => l.adminDashUsageSpendA11y(p, t),
  };
}

String _stateLabel(AppLocalizations l, String code, int count) =>
    switch (code) {
      'running' => l.adminDashStateRunning(count),
      'review' => l.adminDashStateReview(count),
      'blocked' => l.adminDashStateBlocked(count),
      'pending' => l.adminDashStatePending(count),
      _ => '$code $count',
    };

/// One session in "Tasks left": tap opens its tasks and to-do lines, tap again closes. Read-only text.
class _TasksLeftTile extends StatefulWidget {
  const _TasksLeftTile({required this.session});

  final AdminSession session;

  @override
  State<_TasksLeftTile> createState() => _TasksLeftTileState();
}

class _TasksLeftTileState extends State<_TasksLeftTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final session = widget.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SisSettingsRow(
          key: ValueKey('admin-dash-tasks-${session.name}'),
          icon: Icons.checklist_rounded,
          title: session.name,
          showArrow: false,
          onTap: () => setState(() => _open = !_open),
          subtitle: session.counts.isEmpty
              ? null
              : session.counts.entries
                    .map((e) => _stateLabel(l, e.key, e.value))
                    .join('  '),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in session.rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.state, style: TextStyle(color: t.muted)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(r.goal)),
                      ],
                    ),
                  ),
                for (final line in session.todo)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(line, style: TextStyle(color: t.muted)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
