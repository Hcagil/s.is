import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

class AdminCardsFilters extends StatelessWidget {
  const AdminCardsFilters({
    super.key,
    required this.controller,
    required this.state,
    required this.type,
    required this.value,
    required this.values,
    required this.onQuery,
    required this.onState,
    required this.onType,
    required this.onValue,
  });

  final TextEditingController controller;
  final String? state;
  final String? type;
  final String? value;
  final List<String> values;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onState;
  final ValueChanged<String?> onType;
  final ValueChanged<String?> onValue;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('admin-cards-search'),
            controller: controller,
            onChanged: onQuery,
            decoration: InputDecoration(
              hintText: l.adminCardsSearch,
              prefixIcon: const Icon(Icons.search_rounded),
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('admin-cards-state-all'),
                label: Text(l.adminCardsAll),
                selected: state == null,
                onSelected: (_) => onState(null),
              ),
              ChoiceChip(
                key: const ValueKey('admin-cards-state-active'),
                label: Text(l.adminCardsActive),
                selected: state == 'active',
                onSelected: (_) => onState('active'),
              ),
              ChoiceChip(
                key: const ValueKey('admin-cards-state-proposed'),
                label: Text(l.adminCardsProposed),
                selected: state == 'proposed',
                onSelected: (_) => onState('proposed'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('admin-cards-type-all'),
                label: Text(l.adminCardsAll),
                selected: type == null,
                onSelected: (_) => onType(null),
              ),
              ChoiceChip(
                key: const ValueKey('admin-cards-type-rule'),
                label: Text(l.adminCardsRule),
                selected: type == 'rule',
                onSelected: (_) => onType('rule'),
              ),
              ChoiceChip(
                key: const ValueKey('admin-cards-type-app'),
                label: Text(l.adminCardsApp),
                selected: type == 'app',
                onSelected: (_) => onType('app'),
              ),
            ],
          ),
          if (type != null && values.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('admin-cards-value-all'),
                  label: Text(l.adminCardsAll),
                  selected: value == null,
                  onSelected: (_) => onValue(null),
                ),
                ...values.map(
                  (v) => ChoiceChip(
                    key: ValueKey('admin-cards-value-$v'),
                    label: Text(v),
                    selected: value == v,
                    onSelected: (_) => onValue(v),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
