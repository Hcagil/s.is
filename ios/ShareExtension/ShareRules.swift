import Foundation

/// The size and text rules of the iPhone share extension, kept pure so tests can reach them.
enum ShareRules {
  // Caps so a huge share cannot fill the phone (bytes; the photo cap is lib/features/chat/domain/file_attachment.dart maxFileBytes) and the app's message length limit.
  static let maxVideoBytes = 1 << 30
  static let maxPhotoBytes = 50 * 1024 * 1024
  static let maxTextChars = 4000

  /// An unreadable size (nil) counts as too big.
  static func allowsFile(size: Int?, isVideo: Bool) -> Bool {
    guard let size = size else { return false }
    return size <= (isVideo ? maxVideoBytes : maxPhotoBytes)
  }

  /// Joins the parts with newlines, keeps maxTextChars UTF-16 units like the app's limit, never ends in the middle of a surrogate pair.
  static func clippedText(_ parts: [String]) -> String {
    var units = Array(parts.joined(separator: "\n").utf16.prefix(maxTextChars))
    if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
  }
}
