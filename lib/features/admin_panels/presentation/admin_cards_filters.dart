import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

class AdminCardsFilters extends StatelessWidget {
  const AdminCardsFilters({
    super.key,
    required this.controller,
    required this.filterCount,
    required this.onQuery,
    required this.onOpenFilters,
  });

  final TextEditingController controller;
  final int filterCount;
  final ValueChanged<String> onQuery;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('admin-cards-search'),
              controller: controller,
              onChanged: onQuery,
              decoration: InputDecoration(
                hintText: l.adminCardsSearch,
                prefixIcon: const Icon(Icons.search_rounded),
                border: InputBorder.none,
              ),
            ),
          ),
          Semantics(
            label: filterCount > 0 ? l.adminCardsFiltersOn(filterCount) : null,
            button: true,
            onTap: onOpenFilters,
            excludeSemantics: filterCount > 0,
            child: IconButton(
              key: const ValueKey('admin-cards-filter-button'),
              tooltip: l.adminCardsFilters,
              onPressed: onOpenFilters,
              icon: filterCount == 0
                  ? const Icon(Icons.tune_rounded)
                  : Badge(
                      key: const ValueKey('admin-cards-filter-badge'),
                      label: Text('$filterCount'),
                      child: const Icon(Icons.tune_rounded),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
