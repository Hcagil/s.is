import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'message_menu_card.dart';

/// The floating confirmation before the phone's maps app opens: true to open,
/// false or null to stay.
Future<bool?> confirmOpenInMaps(BuildContext context, {required String place}) {
  final anchor = Rect.fromCenter(
    center: MediaQuery.sizeOf(context).center(Offset.zero),
    width: 0,
    height: 0,
  );
  return showFloatingCard<bool>(
    context,
    anchor: anchor,
    highlightAnchor: false,
    cardKey: const ValueKey('open-maps-card'),
    child: Builder(
      builder: (card) {
        final l = AppLocalizations.of(card);
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.locationOpenTitle,
                style: Theme.of(card).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                place,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(card).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('open-maps-cancel'),
                      onPressed: () => Navigator.of(card).pop(false),
                      child: Text(l.locationCancel),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('open-maps-confirm'),
                      onPressed: () => Navigator.of(card).pop(true),
                      child: Text(l.locationOpen),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}
