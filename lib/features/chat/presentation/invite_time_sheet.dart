import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';

/// Opens the time-limit card. [current] is the link's present limit in days (null = no limit).
/// Returns the chosen limit wrapped in a record so "No limit" (null days) differs from "closed without Save" (returns null).
Future<({int? days})?> showInviteTimeSheet(
  BuildContext context, {
  required int? current,
}) {
  return showModalBottomSheet<({int? days})>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    builder: (_) => _TimeSheet(current: current),
  );
}

class _TimeSheet extends StatefulWidget {
  const _TimeSheet({required this.current});

  final int? current;

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  int? _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.current;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final primary = Theme.of(context).colorScheme.primary;

    Widget row(int? value, String label) {
      final selected = _picked == value;
      final id = value == null ? 'none' : '$value';
      return InkWell(
        key: ValueKey('invite-time-$id'),
        onTap: () => setState(() => _picked = value),
        child: Padding(
          padding: SisTokens.settingsRowPadding,
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? primary : t.muted,
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          key: const ValueKey('invite-time-card'),
          color: t.surfaceHigh,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Text(
                      l.groupInviteTimeLimit,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 8),
                  row(null, l.groupInviteNoLimit),
                  row(1, l.groupInviteDays(1)),
                  row(7, l.groupInviteDays(7)),
                  row(30, l.groupInviteDays(30)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      l.groupInviteTimeNote,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: t.muted),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const ValueKey('invite-time-save'),
                        onPressed: () =>
                            Navigator.of(context).pop((days: _picked)),
                        child: Text(l.commonSave),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
