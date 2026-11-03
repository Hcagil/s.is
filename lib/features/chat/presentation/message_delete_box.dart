import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import 'message_menu_card.dart';

/// Enum representing the user's choice in the delete confirmation dialog.
enum DeleteChoice {
  /// The user cancelled the deletion.
  cancel,

  /// The user wants to delete the message for themselves only.
  forMe,

  /// The user wants to delete the message for everyone.
  forAll,
}

/// Shows a Telegram-style floating card to confirm message deletion.
///
/// Returns [DeleteChoice.forMe] if the user confirms without checking the
/// "for everyone" option, [DeleteChoice.forAll] if they check it, or
/// [DeleteChoice.cancel] if they cancel.
Future<DeleteChoice> showMessageDeleteBox(
  BuildContext context, {
  String? checkLabel,
  bool mediaNote = false,
}) async {
  final anchor = Rect.fromCenter(
    center: MediaQuery.sizeOf(context).center(Offset.zero),
    width: 0,
    height: 0,
  );
  return await showFloatingCard<DeleteChoice>(
        context,
        anchor: anchor,
        highlightAnchor: false,
        cardKey: const ValueKey('delete-card'),
        child: Builder(
          builder: (card) {
            final l = AppLocalizations.of(card);
            final scheme = Theme.of(card).colorScheme;
            final muted = SisBrand.of(card).muted;
            var checked = false;
            return StatefulBuilder(
              builder: (context, setState) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l.messageDeleteQuestion),
                    if (mediaNote) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 14, color: muted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              l.messageDeleteMediaNote,
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (checkLabel != null) ...[
                      const SizedBox(height: 12),
                      InkWell(
                        key: const ValueKey('delete-also'),
                        onTap: () => setState(() => checked = !checked),
                        child: Row(
                          children: [
                            Checkbox(
                              value: checked,
                              onChanged: (v) =>
                                  setState(() => checked = v ?? !checked),
                            ),
                            Expanded(child: Text(checkLabel)),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton(
                          key: const ValueKey('delete-confirm'),
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                          ),
                          onPressed: () => Navigator.of(card).pop(
                            checked ? DeleteChoice.forAll : DeleteChoice.forMe,
                          ),
                          child: Text(l.messageDeleteConfirm),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          key: const ValueKey('delete-cancel'),
                          onPressed: () =>
                              Navigator.of(card).pop(DeleteChoice.cancel),
                          child: Text(l.messageDeleteCancel),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ) ??
      DeleteChoice.cancel;
}
