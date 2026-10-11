import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import 'message_menu_card.dart';
import 'sticker_cutout_page.dart';
import 'sticker_draft.dart';
import 'sticker_editor_page.dart';
import 'sticker_gallery_page.dart';
import 'sticker_maker_widgets.dart';

/// The panel's "+ New" start: a small card, then the gallery.
Future<void> openStickerMaker(BuildContext context, WidgetRef ref) async {
  final anchor = Rect.fromCenter(
    center: MediaQuery.sizeOf(context).center(Offset.zero),
    width: 0,
    height: 0,
  );
  final result = await showFloatingCard<bool>(
    context,
    anchor: anchor,
    highlightAnchor: false,
    cardKey: const ValueKey('maker-start-card'),
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
                l.stickerCreateTitle,
                style: Theme.of(card).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('maker-use-photo'),
                onPressed: () => Navigator.of(card).pop(true),
                child: Text(l.makerUsePhoto),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('maker-cancel-card'),
                onPressed: () => Navigator.of(card).pop(false),
                child: Text(l.makerCancel),
              ),
            ],
          ),
        );
      },
    ),
  );

  if (result != true || !context.mounted) return;
  await startStickerMaker(context, ref);
}

/// Gallery, square crop, then the cut-out step (or the editor when this
/// phone cannot cut out). The cut-out arrives later and is swapped in.
Future<void> startStickerMaker(
  BuildContext context,
  WidgetRef ref, {
  String? albumId,
}) async {
  final picked = await pickStickerPhoto(context);
  if (picked == null || !context.mounted) return;
  final jpeg = picked.bytes;
  final codec = await ui.instantiateImageCodec(
    jpeg,
    targetWidth: 512,
    targetHeight: 512,
  );
  final frame = await codec.getNextFrame();
  if (!context.mounted) return;
  final draft = StickerDraft()..entryAlbumId = albumId;
  draft.setPhoto(frame.image);
  final cutter = ref.read(stickerCutterProvider);
  final supported = await cutter.supported();
  if (!context.mounted) {
    draft.dispose();
    return;
  }
  draft.cutOutSupported = supported;
  if (supported) {
    draft.cutOut = true;
    unawaited(
      cutter.mask(jpeg).then((m) async {
        if (draft.closed) return;
        if (m == null) {
          // The member just sees the whole image; once in the log is enough.
          debugPrint('sis.sticker cut-out unavailable, showing whole image');
          draft.setCutOut(false);
        } else {
          await draft.setMask(m);
        }
      }),
    );
  }
  await Navigator.of(context).push(
    stickerMakerRoute(
      supported
          ? StickerCutoutPage(draft: draft)
          : StickerEditorPage(draft: draft),
    ),
  );
  draft.dispose();
}
