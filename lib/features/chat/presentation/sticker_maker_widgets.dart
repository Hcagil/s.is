import 'package:flutter/material.dart';

import '../../../app/swipe_back.dart';
import '../../../app/theme.dart';
import 'sticker_draft.dart';
import 'sticker_painter.dart';

/// A maker page route that finishes with true when the sticker was saved.
/// The pages draw with the finger, so the page-wide swipe back is off.
Route<bool> stickerMakerRoute(Widget page) =>
    MaterialPageRoute<bool>(settings: noSwipeBack, builder: (_) => page);

/// The square checkerboard-backed preview of the sticker; drags report
/// points in sticker space.
class MakerPreview extends StatelessWidget {
  /// Creates a preview of [draft].
  const MakerPreview({
    super.key,
    required this.draft,
    this.cut = 0,
    this.overlays = true,
    this.onStart,
    this.onUpdate,
  });

  /// The sticker draft to preview.
  final StickerDraft draft;

  /// 0 whole image, 1 cut-out, between fades.
  final double cut;

  /// Whether pen strokes and text show.
  final bool overlays;

  /// Called when a finger goes down.
  final void Function(Offset point)? onStart;

  /// Called when the finger moves.
  final void Function(Offset point)? onUpdate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: LayoutBuilder(
                builder: (context, box) {
                  return KeyedSubtree(
                    key: const ValueKey('maker-preview'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanDown: onStart != null
                          ? (d) => onStart!(_pt(d.localPosition, box.maxWidth))
                          : null,
                      onPanUpdate: onUpdate != null
                          ? (d) => onUpdate!(_pt(d.localPosition, box.maxWidth))
                          : null,
                      child: Stack(
                        children: [
                          const CustomPaint(
                            painter: _Checker(),
                            size: Size.infinite,
                          ),
                          CustomPaint(
                            painter: StickerPainter(
                              draft,
                              cut: cut,
                              overlays: overlays,
                            ),
                            size: Size.infinite,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Offset _pt(Offset local, double side) => local / side * stickerSpace;
}

class _Checker extends CustomPainter {
  const _Checker();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    const cell = 12.0;
    for (var row = 0; row < (size.height / cell).ceil(); row++) {
      for (var col = 0; col < (size.width / cell).ceil(); col++) {
        paint.color = (row + col) % 2 == 0
            ? const Color(0xFF34343A)
            : const Color(0xFF2A2A2E);
        canvas.drawRect(
          Rect.fromLTWH(col * cell, row * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A row of the eight maker colours.
class MakerSwatches extends StatelessWidget {
  /// Creates the colour row.
  const MakerSwatches({
    super.key,
    required this.selected,
    required this.onPick,
  });

  /// The currently selected colour.
  final Color selected;

  /// Called when a colour is tapped.
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < makerColours.length; i++)
          GestureDetector(
            key: ValueKey('maker-colour-$i'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onPick(makerColours[i]),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: makerColours[i],
                border: Border.all(
                  color: selected == makerColours[i]
                      ? SisBrand.of(context).brand
                      : (makerColours[i] == const Color(0xFF111111)
                            ? const Color(0xFF555555)
                            : Colors.transparent),
                  width: selected == makerColours[i] ? 3 : 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A segmented choice; each label has the key `<keyPrefix>-<index>`.
class MakerSegments extends StatelessWidget {
  /// Creates the segments.
  const MakerSegments({
    super.key,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'maker-seg',
  });

  /// The segment labels.
  final List<String> labels;

  /// The selected index.
  final int selected;

  /// Called with the tapped index.
  final ValueChanged<int> onChanged;

  /// Prefix of the label keys.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (var i = 0; i < labels.length; i++)
          ButtonSegment<int>(
            value: i,
            label: Text(
              labels[i],
              key: ValueKey('$keyPrefix-$i'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
