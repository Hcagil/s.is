import 'package:flutter/material.dart';

import '../../../app/controls.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/alert_settings.dart';

Future<AlertChoice?> showAlertChoiceSheet(
  BuildContext context, {
  required String title,
  required AlertChoice current,
}) {
  return showModalBottomSheet<AlertChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ChoiceSheet(title: title, current: current),
  );
}

class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({required this.title, required this.current});

  final String title;
  final AlertChoice current;

  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  late AlertChoice _picked = widget.current;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SisChoiceCard<AlertChoice>(
              key: const ValueKey('alert-choice-byDefault'),
              value: AlertChoice.byDefault,
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              title: l.alertChoiceDefault,
              subtitle: l.alertChoiceDefaultHint,
            ),
            SisChoiceCard<AlertChoice>(
              key: const ValueKey('alert-choice-on'),
              value: AlertChoice.on,
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              title: l.alertChoiceOn,
            ),
            SisChoiceCard<AlertChoice>(
              key: const ValueKey('alert-choice-off'),
              value: AlertChoice.off,
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              title: l.alertChoiceOff,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('alert-choice-save'),
                onPressed: () => Navigator.of(context).pop(_picked),
                child: Text(l.commonSave),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
