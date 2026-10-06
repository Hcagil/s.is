/// A release note read as a version plus bullet points.
final class WhatsNewNote {
  const WhatsNewNote({
    required this.text,
    this.version,
    this.bullets = const [],
  });

  /// The raw message body, always kept so nothing is ever dropped.
  final String text;

  /// e.g. '0.31', or null when the note has no version line.
  final String? version;

  final List<String> bullets;

  /// True when the note reads as a version plus at least one bullet.
  bool get isStructured => version != null && bullets.isNotEmpty;
}

/// Never throws. Reads [body] line by line (split on \n, trim each line, '\r' ignored, empty lines dropped).
/// The FIRST non-empty line is the version line if it matches (case-insensitive) the RegExp
///   r'^(?:v|version\s+)?(\d+\.\d+(?:\.\d+)?)$'
/// (so '0.31', 'v0.31', 'Version 0.31', 'version 1.2.3' all give version = group 1).
/// Every remaining non-empty line is a bullet, with ONE leading marker removed if present:
/// one of '-', '*', '•', '–' followed by optional spaces (use RegExp(r'^[-*•–]\s*') ), then trimmed;
/// a line that is empty after removing the marker is dropped.
/// If the first line is not a version line: version = null and bullets = const [] (plain note).
/// text is always the original [body] unchanged.
WhatsNewNote parseWhatsNewNote(String body) {
  final lines = body
      .split('\n')
      .map((line) => line.replaceAll('\r', '').trim())
      .where((line) => line.isNotEmpty)
      .toList();

  if (lines.isEmpty) {
    return WhatsNewNote(text: body);
  }

  final versionRx = RegExp(
    r'^(?:v|version\s+)?(\d+\.\d+(?:\.\d+)?)$',
    caseSensitive: false,
  );
  final bulletRx = RegExp(r'^[-*•–]\s*');

  String? version;
  final bullets = <String>[];

  final firstLine = lines[0];
  final versionMatch = versionRx.firstMatch(firstLine);

  if (versionMatch != null) {
    version = versionMatch.group(1)!;
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      final bulletLine = line.replaceAll(bulletRx, '').trim();
      if (bulletLine.isNotEmpty) {
        bullets.add(bulletLine);
      }
    }
  }

  return WhatsNewNote(text: body, version: version, bullets: bullets);
}
