import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';
import '../domain/admin_models.dart';

class AdminTasksView extends ConsumerStatefulWidget {
  const AdminTasksView({super.key});

  @override
  ConsumerState<AdminTasksView> createState() => _AdminTasksViewState();
}

class _AdminTasksViewState extends ConsumerState<AdminTasksView> {
  String? _open;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(adminPanelsProvider);
    final l = AppLocalizations.of(context);

    if (!s.hasSnapshot) {
      return const Align(
        alignment: Alignment.topCenter,
        child: SisProgressLine(),
      );
    }

    final tasks = s.snapshot.tasks
        .where((t) => !s.decidedTasks.contains(t.id))
        .toList();

    if (tasks.isEmpty) {
      return Center(child: Text(l.adminTasksEmpty));
    }

    const groups = ['M', 'C', 'S'];

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [for (final group in groups) ..._buildGroup(tasks, group, l)],
    );
  }

  List<Widget> _buildGroup(
    List<AdminTask> tasks,
    String group,
    AppLocalizations l,
  ) {
    final title = group == 'M'
        ? l.adminBoxM
        : group == 'C'
        ? l.adminBoxC
        : l.adminBoxS;

    final groupTasks = tasks.where((t) => t.group == group).toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    if (groupTasks.isEmpty) {
      return [];
    }

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
        child: Text(
          '$title (${groupTasks.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      for (final t in groupTasks)
        Column(
          key: ValueKey('admin-task-${t.id}'),
          children: [
            SisSettingsRow(
              icon: Icons.checklist_rounded,
              title: t.name,
              subtitle: t.change,
              onTap: () => setState(() => _open = _open == t.id ? null : t.id),
            ),
            if (_open == t.id)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (t.basis.isNotEmpty)
                      Text(
                        '${l.adminBasis}: ${t.basis.join(', ')}',
                        style: TextStyle(color: SisBrand.of(context).muted),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: ValueKey('admin-task-go-${t.id}'),
                            onPressed: _busy ? null : () => _decide(t.id, true),
                            child: Text(l.adminGo),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            key: ValueKey('admin-task-discard-${t.id}'),
                            onPressed: _busy
                                ? null
                                : () => _decide(t.id, false),
                            child: Text(l.adminDiscard),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
    ];
  }

  Future<void> _decide(String id, bool go) async {
    setState(() => _busy = true);
    final f = await ref
        .read(adminPanelsProvider.notifier)
        .decideTask(id, go: go);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (f == null) _open = null;
    });
    final l = AppLocalizations.of(context);
    showSisNotice(
      context,
      f == null ? l.adminDecided : l.adminSendFailed,
      isError: f != null,
    );
  }
}
