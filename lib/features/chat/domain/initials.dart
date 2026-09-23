/// Up to two initials for an avatar: the first letter of each of the first
/// two words, upper-cased. "?" when the name has no letters to show.
String initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final letters = words
      .take(2)
      .map((w) => String.fromCharCode(w.runes.first).toUpperCase());
  return letters.isEmpty ? '?' : letters.join();
}
