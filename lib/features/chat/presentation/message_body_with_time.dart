part of 'message_screen.dart';

/// A message body with its timestamp: inline at the end of the last line
/// when it fits there (WhatsApp-style, "ok  12:04"), otherwise dropped to
/// its own row below the body, bottom-right -- the layout the bubble used
/// before this widget existed.
///
/// [body] and [time] are always built as two separate widgets carrying their
/// original keys and exact text, never merged into one `Text`/`TextSpan`: a
/// widget test finds each with `find.text()` -- except a still-sending
/// bubble ([Message.sending]), whose time slot is an [Icon]
/// (`Icons.schedule_rounded`) under the same `time-<id>` key, found with
/// `find.byIcon`/`find.byKey` instead.
class _BodyWithTime extends StatelessWidget {
  const _BodyWithTime({
    required this.message,
    required this.bodyStyle,
    required this.linkColor,
    required this.maxContentWidth,
    required this.topPadding,
    required this.timeText,
    required this.timeStyle,
    this.highlightQuery,
  });

  final Message message;
  final TextStyle bodyStyle;
  final Color linkColor;

  /// The active in-chat search query, if any -- passed straight through to
  /// both [_LinkedText]s below.
  final String? highlightQuery;

  /// The bubble's real content column: its outer cap minus padding and,
  /// for a "mine" bubble, its always-laid-out border. Passed down from
  /// [_Bubble], which is the one place that inset is defined, so this
  /// widget never keeps its own copy of that arithmetic to drift from it.
  final double maxContentWidth;
  final double topPadding;
  final String timeText;
  final TextStyle timeStyle;

  static const _gap = 6.0;

  /// The pending-send icon's size, in place of the clock time while
  /// [Message.sending] -- close to [timeStyle]'s usual font size (11) so it
  /// reads as about the same weight in the same corner.
  static const _clockSize = 12.0;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // Text/Text.rich merge the given style onto the ambient DefaultTextStyle
    // (which is where the app's Manrope font family comes from); a bare
    // TextStyle here would measure in the platform default font instead and
    // report the wrong width.
    final defaultStyle = DefaultTextStyle.of(context).style;
    // ponytail: measured as one plain span rather than the linked spans
    // _LinkedText actually renders -- a link's style only changes color and
    // underline, never font size/weight/family, so the two wrap identically.
    final bodyPainter = TextPainter(
      text: TextSpan(text: message.body, style: defaultStyle.merge(bodyStyle)),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: maxContentWidth);
    final lines = bodyPainter.computeLineMetrics();
    final lastLineWidth = lines.last.width;
    final bodyHeight = bodyPainter.height;
    var bodyWidth = 0.0;
    for (final line in lines) {
      if (line.width > bodyWidth) bodyWidth = line.width;
    }
    // Still sending: a small SIS icon takes the time's place -- never an
    // emoji, which draws from the phone's own font -- sized directly
    // rather than measured as text.
    double timeWidth;
    if (message.sending) {
      timeWidth = _clockSize;
    } else {
      final timePainter = TextPainter(
        text: TextSpan(text: timeText, style: defaultStyle.merge(timeStyle)),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      timeWidth = timePainter.width;
      timePainter.dispose();
    }
    bodyPainter.dispose();

    // ponytail: RTL always drops to the own-row layout below, never inline.
    // The fits math above assumes a line's trailing edge is the column's
    // right edge (true for LTR); measuring an RTL line's *visual* end would
    // need glyph-level box positions, not just a summed width. Upgrade path:
    // measure with getBoxesForSelection (as the qa Measured helper does) if
    // RTL locales ever ship.
    final fits =
        direction != TextDirection.rtl &&
        lastLineWidth + _gap + timeWidth <= maxContentWidth;

    final timeWidget = message.sending
        ? Icon(
            Icons.schedule_rounded,
            key: ValueKey('time-${message.id}'),
            size: _clockSize,
            color: timeStyle.color,
          )
        : Text(timeText, key: ValueKey('time-${message.id}'), style: timeStyle);

    if (!fits) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(top: topPadding),
            child: _LinkedText(
              message.body,
              key: ValueKey('body-${message.id}'),
              style: bodyStyle,
              linkColor: linkColor,
              highlightQuery: highlightQuery,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Align(alignment: Alignment.centerRight, child: timeWidget),
          ),
        ],
      );
    }

    // Widening to fit the time never needs more than the longest line
    // already wraps to (a longer earlier line already sets the bubble's
    // width) or the last line plus the time (a short, single-line message).
    final targetWidth = math.max(bodyWidth, lastLineWidth + _gap + timeWidth);
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      // A label/quote above the body can be wider than body+time, in which
      // case IntrinsicWidth makes the whole bubble that wide -- but a fixed
      // SizedBox here would still only claim targetWidth, stranding the
      // time mid-bubble instead of at the content's right edge. This custom
      // layout reports targetWidth for the intrinsic (hugging) pass -- same
      // as a Text's own intrinsic width -- but at real layout time fills
      // whatever width the column actually turns out to be, exactly the
      // way a plain Text/RenderParagraph already behaves (see the
      // IntrinsicWidth comment above): _Bubble's own hugging is unaffected,
      // because in the common case (no wider sibling) that real width is
      // targetWidth anyway.
      child: CustomMultiChildLayout(
        delegate: _BodyTimeLayout(
          targetWidth: targetWidth,
          bodyWidth: bodyWidth,
          bodyHeight: bodyHeight,
        ),
        children: [
          LayoutId(
            id: _BodyTimeSlot.body,
            child: _LinkedText(
              message.body,
              key: ValueKey('body-${message.id}'),
              style: bodyStyle,
              linkColor: linkColor,
              highlightQuery: highlightQuery,
            ),
          ),
          LayoutId(id: _BodyTimeSlot.time, child: timeWidget),
        ],
      ),
    );
  }
}

enum _BodyTimeSlot { body, time }

/// Lays the body out at its own (never stretched) [bodyWidth], and the time
/// at the bottom-right of the real column -- [targetWidth] only when nothing
/// wider forces the column open (see [_BodyWithTime]'s [CustomMultiChildLayout]
/// comment for why a plain SizedBox can't do both jobs at once).
class _BodyTimeLayout extends MultiChildLayoutDelegate {
  _BodyTimeLayout({
    required this.targetWidth,
    required this.bodyWidth,
    required this.bodyHeight,
  });

  final double targetWidth;
  final double bodyWidth;
  final double bodyHeight;

  @override
  Size getSize(BoxConstraints constraints) => Size(
    constraints.hasBoundedWidth ? constraints.maxWidth : targetWidth,
    bodyHeight,
  );

  @override
  void performLayout(Size size) {
    layoutChild(_BodyTimeSlot.body, BoxConstraints.tightFor(width: bodyWidth));
    positionChild(_BodyTimeSlot.body, Offset.zero);
    final timeSize = layoutChild(
      _BodyTimeSlot.time,
      BoxConstraints.loose(size),
    );
    positionChild(
      _BodyTimeSlot.time,
      Offset(size.width - timeSize.width, size.height - timeSize.height),
    );
  }

  @override
  bool shouldRelayout(covariant _BodyTimeLayout oldDelegate) =>
      targetWidth != oldDelegate.targetWidth ||
      bodyWidth != oldDelegate.bodyWidth ||
      bodyHeight != oldDelegate.bodyHeight;
}
