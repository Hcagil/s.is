import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'sticker_draft.dart';
import 'sticker_editor_page.dart';
import 'sticker_maker_widgets.dart';

/// The cut-out step: "Whole image" or "Cut-out", with an erase and restore
/// brush. Only shown on phones that can cut a subject out.
class StickerCutoutPage extends StatefulWidget {
  /// Creates the cut-out step for [draft].
  const StickerCutoutPage({super.key, required this.draft});

  /// The sticker being made.
  final StickerDraft draft;

  @override
  State<StickerCutoutPage> createState() => _StickerCutoutPageState();
}

class _StickerCutoutPageState extends State<StickerCutoutPage> {
  bool _erase = true;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('sticker-cutout-page'),
      appBar: AppBar(
        title: Text(l.makerCutoutTitle),
        actions: [
          IconButton(
            key: const ValueKey('maker-ok'),
            icon: const Icon(Icons.check),
            onPressed: _next,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.draft,
        builder: (context, child) {
          final d = widget.draft;
          final ready = d.cutOut && d.hasCutOut;
          final pending = d.cutOut && !d.hasCutOut; // mask not arrived yet
          return Column(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: ready ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 220),
                builder: (_, cut, _) => MakerPreview(
                  draft: d,
                  cut: cut,
                  overlays: false,
                  onStart: ready ? _start : null,
                  onUpdate: ready ? _move : null,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      MakerSegments(
                        keyPrefix: 'maker-mode',
                        labels: [l.makerWhole, l.makerCut],
                        selected: d.cutOut ? 1 : 0,
                        onChanged: (i) => d.setCutOut(i == 1),
                      ),
                      if (d.cutOut) ...[
                        const SizedBox(height: 12),
                        MakerSegments(
                          keyPrefix: 'maker-brush',
                          labels: [l.makerErase, l.makerRestore],
                          selected: _erase ? 0 : 1,
                          onChanged: (i) => setState(() => _erase = i == 0),
                          enabled: !pending,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const ValueKey('maker-undo'),
                                onPressed: d.brush.isEmpty ? null : d.undoBrush,
                                icon: const Icon(Icons.undo),
                                label: Text(l.makerUndo),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const ValueKey('maker-reset'),
                                onPressed: d.brush.isEmpty
                                    ? null
                                    : d.resetBrush,
                                icon: const Icon(Icons.delete_outline),
                                label: Text(l.makerReset),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          pending ? l.makerCutoutPreparing : l.makerBrushHint,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _start(Offset p) {
    widget.draft.addStroke(
      widget.draft.brush,
      MakerStroke(points: [p], width: 14, erase: _erase),
    );
  }

  void _move(Offset p) {
    if (widget.draft.brush.isNotEmpty) {
      widget.draft.addPoint(widget.draft.brush, p);
    }
  }

  Future<void> _next() async {
    final done = await Navigator.of(context)
        .push<bool>(stickerMakerRoute(StickerEditorPage(draft: widget.draft)));
    if (done == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }
}
