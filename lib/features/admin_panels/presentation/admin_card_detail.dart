import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/admin_models.dart';

class AdminCardDetail extends StatelessWidget {
  const AdminCardDetail({super.key, required this.card, required this.onBack});

  final AdminCard card;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('admin-card-back'),
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                card.id,
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SelectableText(
                card.oneLiner,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              _typeStateLine(context, card, l),
              if (card.applies != null)
                _field(context, l.adminCardApplies, card.applies!),
              if (card.area != null)
                _field(context, l.adminCardArea, card.area!),
              if (card.when.isNotEmpty)
                _field(context, l.adminCardWhen, card.when.join(', ')),
              if (card.words.isNotEmpty)
                _field(context, l.adminCardWords, card.words.join('\n')),
              if (card.allows != null)
                _field(context, l.adminCardAllows, card.allows!),
              if (card.forbids != null)
                _field(context, l.adminCardForbids, card.forbids!),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _typeStateLine(
  BuildContext context,
  AdminCard card,
  AppLocalizations l,
) {
  final typeLabel = card.type == 'app' ? l.adminCardsApp : l.adminCardsRule;
  final stateLabel = card.state == 'proposed'
      ? l.adminCardsProposed
      : l.adminCardsActive;
  return SelectableText(
    '$typeLabel - $stateLabel',
    style: TextStyle(color: SisBrand.of(context).muted),
  );
}

Widget _field(BuildContext context, String label, String body) {
  return Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: SisBrand.of(context).muted)),
        const SizedBox(height: 4),
        SelectableText(body),
      ],
    ),
  );
}
