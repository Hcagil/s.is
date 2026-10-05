part of 'message_screen.dart';

/// Message text with its links tappable, opening in the browser.
class _LinkedText extends ConsumerStatefulWidget {
  const _LinkedText(
    this.text, {
    super.key,
    required this.style,
    required this.linkColor,
    this.highlightQuery,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  /// The active in-chat search query, if any: every match is highlighted,
  /// not just the current hit (see `_Bubble.isCurrentHit` for that).
  final String? highlightQuery;

  @override
  ConsumerState<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends ConsumerState<_LinkedText> {
  // One recognizer per link, disposed with the widget: a recognizer that is
  // never disposed leaks its gesture arena entry.
  final _taps = <TapGestureRecognizer>[];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  Future<void> _open(Uri link) async {
    final opened = await ref.read(linkOpenerProvider).open(link);
    if (!opened && mounted) {
      showSisNotice(context, 'Could not open ${link.host}', isError: true);
    }
  }

  /// [text], split around every case-insensitive match of the active search
  /// query and given a highlighted background. Unlike a link's style, this
  /// never touches links (a match inside a link stays link-styled only --
  /// known simplification, links are rare inside a search hit).
  List<TextSpan> _highlightSpans(String text) {
    final query = widget.highlightQuery;
    if (query == null || query.trim().isEmpty) {
      return [TextSpan(text: text)];
    }
    final offsets = matchOffsets(text, query);
    if (offsets.isEmpty) {
      return [TextSpan(text: text)];
    }
    final length = query.trim().length;
    final spans = <TextSpan>[];
    var start = 0;
    for (final offset in offsets) {
      if (start < offset) {
        spans.add(TextSpan(text: text.substring(start, offset)));
      }
      spans.add(
        TextSpan(
          text: text.substring(offset, offset + length),
          // The app's own "unread" amber, reused as the search highlight.
          style: const TextStyle(
            backgroundColor: Color(0xFFFFD54F),
            color: Colors.black87,
          ),
        ),
      );
      start = offset + length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final segments = linkSegments(widget.text);
    final highlighting =
        widget.highlightQuery != null &&
        widget.highlightQuery!.trim().isNotEmpty;
    if (segments.every((s) => s.link == null) && !highlighting) {
      return Text(widget.text, style: widget.style);
    }
    final spans = <TextSpan>[];
    for (final s in segments) {
      final link = s.link;
      if (link == null) {
        spans.addAll(_highlightSpans(s.text));
        continue;
      }
      final tap = TapGestureRecognizer()..onTap = () => _open(link);
      _taps.add(tap);
      spans.add(
        TextSpan(
          text: s.text,
          recognizer: tap,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
          ),
        ),
      );
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
