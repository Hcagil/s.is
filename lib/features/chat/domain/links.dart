import 'message.dart';

/// A run of message text: plain, or a link to open.
final class TextSegment {
  const TextSegment(this.text, [this.link]);

  final String text;

  /// Set when [text] is a link; always http or https.
  final Uri? link;
}

// A web address: http(s)://… or www.…, up to whitespace or an angle bracket
// or quote. Trailing punctuation is trimmed after the match.
final _link = RegExp(
  r'''(?:https?://|www\.)[^\s<>"']+''',
  caseSensitive: false,
);
const _trailing = '.,;:!?';

/// [text] split into plain runs and links, in order; joining every
/// [TextSegment.text] gives [text] back unchanged. Only http and https links
/// are recognised, so a message can never smuggle in another scheme.
List<TextSegment> linkSegments(String text) {
  final out = <TextSegment>[];
  var at = 0;
  for (final m in _link.allMatches(text)) {
    var raw = m.group(0)!;
    // "see https://x.com." ends the sentence, not the address; a closing
    // bracket belongs to the address only when it also opened one.
    while (raw.isNotEmpty) {
      final last = raw[raw.length - 1];
      final unbalanced =
          last == ')' &&
          '('.allMatches(raw).length < ')'.allMatches(raw).length;
      if (!_trailing.contains(last) && !unbalanced) break;
      raw = raw.substring(0, raw.length - 1);
    }
    final uri = Uri.tryParse(
      raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw,
    );
    if (uri == null || uri.host.isEmpty) continue;
    if (m.start > at) out.add(TextSegment(text.substring(at, m.start)));
    out.add(TextSegment(raw, uri));
    at = m.start + raw.length;
  }
  if (at < text.length) out.add(TextSegment(text.substring(at)));
  return out;
}

/// Every link in [text], in order.
List<Uri> extractLinks(String text) => [
  for (final s in linkSegments(text))
    if (s.link != null) s.link!,
];

/// One shared link: the address and the message it came from.
typedef SharedLink = ({Uri link, Message message});

/// Every link in [messages], in the messages' order; a message with two links
/// gives two entries.
List<SharedLink> sharedLinksIn(List<Message> messages) => [
  for (final m in messages)
    for (final link in extractLinks(m.body)) (link: link, message: m),
];

/// Opens a link outside the app. Its own boundary because the browser is a
/// platform capability, and presentation/ may not import a platform SDK.
abstract interface class LinkOpener {
  /// False when nothing could open it.
  Future<bool> open(Uri link);
}
