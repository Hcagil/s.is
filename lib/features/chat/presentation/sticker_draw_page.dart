import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'sticker_draft.dart';
import 'sticker_maker_widgets.dart';

const List<double> _widths = [1.5, 3.5, 7.0];

/// The draw step: finger-painted pen strokes in a colour and width.
class StickerDrawPage extends StatefulWidget {
  /// Creates the draw step for [draft].
  const StickerDrawPage({super.key, required this.draft});

  /// The sticker being made.
  final StickerDraft draft;

  @override
  State<StickerDrawPage> createState() => _StickerDrawPageState();
}

class _StickerDrawPageState extends State<StickerDrawPage> {
  late final int _before;
  Color _colour = makerColours[2];
  int _width = 1;

  @override
  void initState() {
    super.initState();
    _before = widget.draft.pen.length;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('sticker-draw-page'),
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('maker-cancel'),
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
        title: Text(l.makerDrawTitle),
        actions: [
          IconButton(
            key: const ValueKey('maker-undo'),
            icon: const Icon(Icons.undo),
            onPressed: widget.draft.undoPen,
          ),
          IconButton(
            key: const ValueKey('maker-clear'),
            icon: const Icon(Icons.delete_outline),
            onPressed: widget.draft.clearPen,
          ),
          IconButton(
            key: const ValueKey('maker-ok'),
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: widget.draft,
            builder: (_, _) => MakerPreview(
              draft: widget.draft,
              cut: widget.draft.cutOut && widget.draft.hasCutOut ? 1 : 0,
              onStart: _start,
              onUpdate: _move,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  MakerSwatches(
                    selected: _colour,
                    onPick: (c) => setState(() => _colour = c),
                  ),
                  const SizedBox(height: 12),
                  MakerSegments(
                    keyPrefix: 'maker-width',
                    labels: [l.makerThin, l.makerMedium, l.makerThick],
                    selected: _width,
                    onChanged: (i) => setState(() => _width = i),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _start(Offset p) {
    widget.draft.addStroke(
      widget.draft.pen,
      MakerStroke(points: [p], width: _widths[_width], colour: _colour),
    );
  }

  void _move(Offset p) {
    if (widget.draft.pen.isNotEmpty) {
      widget.draft.addPoint(widget.draft.pen, p);
    }
  }

  void _cancel() {
    widget.draft.restorePen(_before);
    Navigator.of(context).pop();
  }
}
