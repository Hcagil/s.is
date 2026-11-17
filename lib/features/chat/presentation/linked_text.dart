part of 'message_screen.dart';

/// Message text with its links tappable, opening in the browser.
class _LinkedText extends ConsumerStatefulWidget {
  const _LinkedText(
    this.text, {
    super.key,
    required this.style,
    required this.linkColor,
    this.highlightQuery,
    this.shorten,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  /// The active in-chat search query, if any: every match is highlighted,
  /// not just the current hit (see `_Bubble.isCurrentHit` for that).
  final String? highlightQuery;

  /// The link whose text shows shortened (domain and the start of the path):
  /// the link a card is shown for. Tapping it still opens the full link.
  final Uri? shorten;

  @override
  ConsumerState<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends ConsumerState<_LinkedText> {
  bool _expanded = false;

  String _cut(String t) {
    final c = t.characters;
    final head = c.take(foldMessageAfter);
    final next = c.skip(foldMessageAfter).first;
    if (next.trim().isEmpty) return head.toString().trimRight();
    final s = head.toString();
    final i = s.lastIndexOf(RegExp(r'\s'));
    return i <= 0 ? s : s.substring(0, i).trimRight();
  }

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
      showSisNotice(
        context,
        AppLocalizations.of(context).linkOpenFailed(link.host),
        isError: true,
      );
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

  Widget _content(String shown) {
    final segments = linkSegments(shown);
    final highlighting =
        widget.highlightQuery != null &&
        widget.highlightQuery!.trim().isNotEmpty;
    if (segments.every((s) => s.link == null) && !highlighting) {
      return Text(shown, style: widget.style);
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
          text: widget.shorten?.toString() == link.toString()
              ? shortLink(link)
              : s.text,
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

  @override
  Widget build(BuildContext context) {
    _clear();
    final long = widget.text.characters.length > foldMessageAfter;
    if (!long) return _content(widget.text);
    final style = TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: widget.linkColor,
      textStyle: const TextStyle(fontSize: 14),
    );
    final l10n = AppLocalizations.of(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _content(_expanded ? widget.text : _cut(widget.text)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: ValueKey(_expanded ? 'read-less' : 'read-more'),
            onPressed: () => setState(() => _expanded = !_expanded),
            style: style,
            child: Text(
              _expanded ? l10n.messageShowLess : l10n.messageShowMore,
            ),
          ),
        ),
      ],
    );
    // Open/close takes 200 ms; with reduced motion it is a 150 ms fade instead.
    if (MediaQuery.disableAnimationsOf(context)) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: KeyedSubtree(key: ValueKey(_expanded), child: body),
      );
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topLeft,
      child: body,
    );
  }
}
