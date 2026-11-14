import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/conversation_tile.dart' show FadeDivider;
import '../application/admin_panels_controller.dart';
import '../domain/admin_card_filter.dart';
import 'admin_card_detail.dart';
import 'admin_cards_filters.dart';

class AdminCardsView extends ConsumerStatefulWidget {
  const AdminCardsView({super.key});

  @override
  ConsumerState<AdminCardsView> createState() => _AdminCardsViewState();
}

class _AdminCardsViewState extends ConsumerState<AdminCardsView> {
  String? _open;
  String _query = '';
  String? _state;
  String? _type;
  String? _value;
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(adminPanelsProvider);
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    if (!s.hasSnapshot) {
      return const Align(
        alignment: Alignment.topCenter,
        child: SisProgressLine(),
      );
    }

    final cards = s.snapshot.cards;

    if (cards.isEmpty) {
      return Center(child: Text(l.adminCardsEmpty));
    }

    if (_open != null) {
      final card = cards.where((c) => c.id == _open).firstOrNull;
      if (card != null) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _open = null);
          },
          child: AdminCardDetail(
            key: ValueKey('admin-card-detail-$_open'),
            card: card,
            onBack: () => setState(() => _open = null),
          ),
        );
      }
    }

    final shown = adminFilterCards(
      cards,
      query: _query,
      state: _state,
      type: _type,
      value: _value,
    );

    return Column(
      children: [
        AdminCardsFilters(
          controller: _controller,
          state: _state,
          type: _type,
          value: _value,
          values: _type == null ? const [] : adminCardValues(cards, _type!),
          onQuery: (v) => setState(() => _query = v),
          onState: (v) => setState(() => _state = v),
          onType: (v) => setState(() {
            _type = v;
            _value = null;
          }),
          onValue: (v) => setState(() => _value = v),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text(l.adminCardsNoMatch))
              : ListView(
                  children: [
                    for (final c in shown)
                      Column(
                        key: ValueKey('admin-card-tile-${c.id}'),
                        children: [
                          SisSettingsRow(
                            icon: c.type == 'app'
                                ? Icons.apps_rounded
                                : Icons.rule_rounded,
                            iconColor: c.state == 'proposed' ? t.brand : null,
                            title: c.id,
                            subtitle: c.oneLiner,
                            value: c.state == 'proposed'
                                ? l.adminCardsProposed
                                : l.adminCardsActive,
                            onTap: () => setState(() => _open = c.id),
                          ),
                          const FadeDivider(),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
