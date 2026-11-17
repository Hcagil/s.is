import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/controls.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_drafts.dart';
import '../domain/admin_models.dart';

class AdminQuestionCard extends StatelessWidget {
  const AdminQuestionCard({
    super.key,
    required this.question,
    required this.waiting,
    required this.selected,
    required this.controller,
    required this.onSelected,
    required this.onTextChanged,
    required this.expanded,
    required this.onToggle,
  });

  final AdminQuestion question;
  final bool waiting;
  final int selected;
  final TextEditingController controller;
  final ValueChanged<int> onSelected;
  final VoidCallback onTextChanged;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final firstLine = question.text.split('\n').first;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: ValueKey('admin-question-header-${question.id}'),
            onTap: onToggle,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${question.id}  ${expanded ? question.text : firstLine}',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: expanded ? null : 1,
                    overflow: expanded
                        ? TextOverflow.clip
                        : TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: t.muted,
                ),
              ],
            ),
          ),
          if (expanded && question.ctx.isNotEmpty)
            Text(question.ctx, style: TextStyle(color: t.muted)),
          // The status stays on the closed header too.
          if (waiting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l.adminWaiting, style: TextStyle(color: t.muted)),
            )
          else if (expanded) ...[
            if (question.kind == 'action')
              OutlinedButton(
                key: ValueKey('admin-question-done-${question.id}'),
                onPressed: () => onSelected(0),
                child: Text(selected == 0 ? '${l.adminDone} ✓' : l.adminDone),
              )
            else if (question.kind == 'text')
              _field()
            else ...[
              for (int i = 0; i < question.answers.length; i++)
                SisChoiceCard<int>(
                  value: i,
                  groupValue: selected,
                  onChanged: onSelected,
                  title: question.answers[i],
                  subtitle: i == question.recommended
                      ? l.adminRecommended
                      : null,
                ),
              SisChoiceCard<int>(
                value: question.answers.length,
                groupValue: selected,
                onChanged: onSelected,
                title: l.adminOther,
              ),
              if (selected == question.answers.length) _field(),
            ],
          ],
        ],
      ),
    );
  }

  Widget _field() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        key: ValueKey('admin-question-text-${question.id}'),
        controller: controller,
        onChanged: (_) => onTextChanged(),
        inputFormatters: [LengthLimitingTextInputFormatter(adminDraftMax)],
        minLines: 1,
        maxLines: 4,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
    );
  }
}
