/// Opens the phone's share sheet with text. Never throws.
abstract interface class TextSharer {
  /// Shares [text] through the phone's share sheet.
  Future<void> share(String text);
}
