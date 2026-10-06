import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'message_menu_card.dart';
import 'person_avatar.dart';

/// One member who has read a message, as the readers card shows them.
class Reader {
  const Reader({
    required this.userId,
    required this.name,
    required this.time,
    this.avatarPath,
    this.groupSlot,
  });

  final String userId;
  final String name;

  /// The read time, already formatted (clock time).
  final String time;
  final String? avatarPath;
  final int? groupSlot;
}

/// Opens the readers card ABOVE [anchor] (the "Seen by" pill's global rect,
/// which stays lit), same look as the long-press card. Tapping the title
/// closes it.
Future<void> showReadersCard(
  BuildContext context, {
  required Rect anchor,
  required bool alignEnd,
  required List<Reader> readers,
}) => showFloatingCard<void>(
  context,
  anchor: anchor,
  alignEnd: alignEnd,
  highlightAnchor: true,
  anchorRadius: 20,
  cardKey: const ValueKey('readers-card'),
  child: Builder(
    builder: (card) {
      final scheme = Theme.of(card).colorScheme;
      final l = AppLocalizations.of(card);
      final title = InkWell(
        key: const ValueKey('readers-title'),
        onTap: () => Navigator.of(card).pop(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Row(
            children: [
              Text(
                l.messageSeenBy(readers.length),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Icon(Icons.close, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          for (final r in readers)
            Padding(
              key: ValueKey('reader-${r.userId}'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                children: [
                  PersonAvatar(
                    radius: 13,
                    label: r.name,
                    seed: r.userId,
                    avatarPath: r.avatarPath,
                    groupSlot: r.groupSlot,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      r.name,
                      style: TextStyle(fontSize: 13, color: scheme.onSurface),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    r.time,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  ),
);
