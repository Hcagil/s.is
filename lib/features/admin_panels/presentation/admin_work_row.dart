import 'package:flutter/material.dart';

import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/admin_dashboard.dart';
import 'admin_work_colors.dart';

/// One "running now" row: a thin thread line on the left joining it to its
/// caller, a state dot, and a screen-reader label naming state and caller.
class AdminWorkRow extends StatelessWidget {
  const AdminWorkRow({
    super.key,
    required this.entry,
    required this.entries,
    required this.family,
  });

  final AdminWorkEntry entry;
  final List<AdminWorkEntry> entries;
  final int family;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    final stateWord = switch (entry.state) {
      'running' => l.adminDashWorkStateRunning,
      'shell' => l.adminDashWorkStateShell,
      'stale' => l.adminDashWorkStateStale,
      _ => l.adminDashWorkStateUnknown,
    };

    final caller = adminCallerName(entry, entries);
    final label = caller == null
        ? '${entry.title}, $stateWord'
        : '${entry.title}, ${l.adminDashWorkCalledBy(stateWord, caller)}';

    final dot = adminWorkDotColors[entry.state] ?? t.muted;

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 3,
              child: entry.parent == null
                  ? null
                  : ColoredBox(
                      color: adminThreadColor(family, entry.depth),
                      key: ValueKey(
                        'admin-work-line-${entry.id ?? entry.title}',
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Center(
              child: Container(
                key: ValueKey('admin-work-dot-${entry.id ?? entry.title}'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
            ),
            Expanded(
              child: SisSettingsRow(
                icon: Icons.play_circle_outline_rounded,
                title: entry.title,
                showArrow: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
