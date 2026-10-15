/// A release note read as a version plus bullet points.
final class WhatsNewNote {
  const WhatsNewNote({
    required this.text,
    this.version,
    this.build,
    this.bullets = const [],
  });

  /// The raw message body, always kept so nothing is ever dropped.
  final String text;

  /// e.g. '0.31', or null when the note has no version line.
  final String? version;

  /// The build number of a "0.31.0 (216)" line, null for older notes.
  final int? build;

  final List<String> bullets;

  /// True when the note reads as a version plus at least one bullet.
  bool get isStructured => version != null && bullets.isNotEmpty;
}

/// Never throws. Reads [body] line by line (split on \n, trim each line, '\r' ignored, empty lines dropped).
/// The FIRST non-empty line is the version line if it matches (case-insensitive) the RegExp
///   r'^(?:v|version\s+)?(\d+\.\d+(?:\.\d+)?)$'
/// An optional ' (216)' suffix is the build number.
/// (so '0.31', 'v0.31', 'Version 0.31', 'version 1.2.3' all give version = group 1).
/// Every remaining non-empty line is a bullet, with ONE leading marker removed if present:
/// one of '-', '*', '•', '–' followed by optional spaces (use RegExp(r'^[-*•–]\s*') ), then trimmed;
/// a line that is empty after removing the marker is dropped.
/// If the first line is not a version line: version = null and bullets = const [] (plain note).
/// text is always the original [body] unchanged.
/// A line that is exactly '---' splits the body into English (first) and Turkish (second); [lang] 'tr' picks the second when it is not empty, anything else picks the first. 'sürüm 0.31' also reads as a version line.
WhatsNewNote parseWhatsNewNote(String body, {String lang = 'en'}) {
  final parts = body.split(RegExp(r'^\s*---\s*$', multiLine: true));
  final chosen = lang == 'tr' && parts.length > 1 && parts[1].trim().isNotEmpty
      ? parts[1]
      : parts[0];
  final lines = chosen
      .split('\n')
      .map((line) => line.replaceAll('\r', '').trim())
      .where((line) => line.isNotEmpty)
      .toList();

  if (lines.isEmpty) {
    return WhatsNewNote(text: body);
  }

  final versionRx = RegExp(
    r'^(?:v|version\s+|sürüm\s+)?(\d+\.\d+(?:\.\d+)?)(?:\s*\((\d+)\))?$',
    caseSensitive: false,
  );
  final bulletRx = RegExp(r'^[-*•–]\s*');

  String? version;
  int? build;
  final bullets = <String>[];

  final firstLine = lines[0];
  final versionMatch = versionRx.firstMatch(firstLine);

  if (versionMatch != null) {
    version = versionMatch.group(1)!;
    build = int.tryParse(versionMatch.group(2) ?? '');
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      final bulletLine = line.replaceAll(bulletRx, '').trim();
      if (bulletLine.isNotEmpty) {
        bullets.add(bulletLine);
      }
    }
  }

  return WhatsNewNote(
    text: body,
    version: version,
    build: build,
    bullets: bullets,
  );
}

/// True when version name [a] (e.g. '0.31' or '0.30.17') is higher than [b].
/// Compares dot-separated numbers; a missing part counts as 0; a part that is not a number counts as 0.
bool isNewerVersion(String a, String b) {
  final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
