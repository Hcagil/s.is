import 'message.dart';

/// Case-insensitive start offsets where [query] occurs in [text] --
/// non-overlapping, in order. Empty unless [query] is [isSearchable]: a
/// query the app never searches highlights nothing either.
///
/// For highlighting a search hit in a chat bubble or a list snippet. This is
/// a plain lowercase compare, not the server's Turkish-safe folding (see
/// `ChatRepository.search`): it only needs to agree with the characters the
/// member actually typed and is looking at, not the server's broader match.
List<int> matchOffsets(String text, String query) {
  if (!isSearchable(query)) return const [];
  final trimmed = query.trim();
  final lowerText = text.toLowerCase();
  final lowerQuery = trimmed.toLowerCase();
  final offsets = <int>[];
  var start = 0;
  while (true) {
    final index = lowerText.indexOf(lowerQuery, start);
    if (index < 0) break;
    offsets.add(index);
    start = index + lowerQuery.length;
  }
  return offsets;
}
