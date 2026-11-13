import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';

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
    if (d == null || (d.working.isEmpty && d.sessions.isEmpty)) {
      return Center(child: Text(l.adminDashEmpty));
    }

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
            SisSettingsRow(
              key: ValueKey('admin-dash-work-$i'),
              icon: Icons.play_circle_outline_rounded,
              title: d.working[i],
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
              value: session.contextK == null
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
            if (session.counts.isNotEmpty)
              SisSettingsRow(
                icon: Icons.checklist_rounded,
                title: session.name,
                value: session.counts.entries
                    .map((e) => '${e.key} ${e.value}')
                    .join('  '),
              ),
        ],
      ],
    );
  }
}
