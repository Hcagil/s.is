import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'sticker_draft.dart';
import 'sticker_draw_page.dart';
import 'sticker_maker_widgets.dart';
import 'sticker_save_page.dart';
import 'sticker_text_page.dart';

/// The editor step: add text, draw, then go on to save.
class StickerEditorPage extends StatelessWidget {
  /// Creates the editor for [draft].
  const StickerEditorPage({super.key, required this.draft});

  /// The sticker being made.
  final StickerDraft draft;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('sticker-editor-page'),
      appBar: AppBar(
        title: Text(l.makerEditTitle),
        actions: [
          IconButton(
            key: const ValueKey('maker-text'),
            icon: const Icon(Icons.text_fields),
            onPressed: () => _open(context, StickerTextPage(draft: draft)),
          ),
          IconButton(
            key: const ValueKey('maker-draw'),
            icon: const Icon(Icons.brush_outlined),
            onPressed: () => _open(context, StickerDrawPage(draft: draft)),
          ),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: draft,
            builder: (_, _) => MakerPreview(
              draft: draft,
              cut: draft.cutOut && draft.hasCutOut ? 1 : 0,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    l.makerEditHint,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('maker-next'),
                      onPressed: () => _save(context),
                      child: Text(l.makerToAlbum),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, Widget page) {
    unawaited(Navigator.of(context).push<bool>(stickerMakerRoute(page)));
  }

  Future<void> _save(BuildContext context) async {
    final done = await Navigator.of(context)
        .push<bool>(stickerMakerRoute(StickerSavePage(draft: draft)));
    if (done == true && context.mounted) {
      Navigator.of(context).pop(true);
    }
  }
}
