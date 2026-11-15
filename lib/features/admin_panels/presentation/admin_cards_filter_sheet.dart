import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// Number of chip groups not at their 'all' default.
int adminCardsFilterCount({String? state, String? type, String? value}) =>
    (state != null ? 1 : 0) + (type != null ? 1 : 0) + (value != null ? 1 : 0);

Future<void> showAdminCardsFilterSheet(
  BuildContext context, {
  required Widget Function(BuildContext) builder,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: builder,
);

class AdminCardsFilterSheet extends StatelessWidget {
  const AdminCardsFilterSheet({
    super.key,
    required this.state,
    required this.type,
    required this.value,
    required this.values,
    required this.onState,
    required this.onType,
    required this.onValue,
  });

  final String? state;
  final String? type;
  final String? value;
  final List<String> values;
  final ValueChanged<String?> onState;
  final ValueChanged<String?> onType;
  final ValueChanged<String?> onValue;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            key: const ValueKey('admin-cards-filter-sheet'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                key: const Key('admin-cards-filter-sheet-title'),
                header: true,
                child: Text(
                  l.adminCardsFiltersTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 8),
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
                const SizedBox(height: 8),
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
        ),
      ),
    );
  }
}
