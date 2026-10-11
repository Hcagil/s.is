/// What a web page says about itself (Open Graph, Twitter and plain tags).
final class LinkPageInfo {
  /// Creates the info of one page.
  const LinkPageInfo({
    required this.title,
    this.description,
    this.site,
    this.image,
  });

  /// 1 to 200 characters, text only.
  final String title;

  /// At most 400 characters, text only.
  final String? description;

  /// The site's name, at most 100 characters, text only.
  final String? site;

  /// Absolute http(s) address of the page's picture.
  final Uri? image;
}

final _metaTag = RegExp(r'<meta\s[^>]*>', caseSensitive: false, dotAll: true);
final _attr = RegExp(r'''([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _titleTag = RegExp(
  r'<title[^>]*>(.*?)</title>',
  caseSensitive: false,
  dotAll: true,
);
final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');
final _controls = RegExp(r'[\u0000-\u001F\u007F-\u009F]');
final _spaces = RegExp(r'\s+');

/// Reads [html], the start of the page at [base]; null when it has no title.
LinkPageInfo? parseLinkPage(Uri base, String html) {
  final head = html.length > 300000 ? html.substring(0, 300000) : html;
  final meta = <String, String>{};
  for (final tag in _metaTag.allMatches(head).map((m) => m.group(0)!)) {
    String? key;
    String? content;
    for (final a in _attr.allMatches(tag)) {
      final name = a.group(1)!.toLowerCase();
      final value = a.group(2) ?? a.group(3) ?? '';
      if (name == 'property' || name == 'name') {
        key ??= value.toLowerCase();
      } else if (name == 'content') {
        content = value;
      }
    }
    if (key != null && content != null) meta.putIfAbsent(key, () => content!);
  }
  final title = _clean(
    meta['og:title'] ??
        meta['twitter:title'] ??
        _titleTag.firstMatch(head)?.group(1),
  );
  if (title.isEmpty) return null;
  final description = _clean(
    meta['og:description'] ??
        meta['twitter:description'] ??
        meta['description'],
  );
  final site = _clean(meta['og:site_name']);
  return LinkPageInfo(
    title: _cap(title, 200),
    description: description.isEmpty ? null : _cap(description, 400),
    site: site.isEmpty ? null : _cap(site, 100),
    image: _image(
      base,
      meta['og:image'] ??
          meta['og:image:secure_url'] ??
          meta['twitter:image'] ??
          meta['twitter:image:src'],
    ),
  );
}

Uri? _image(Uri base, String? raw) {
  if (raw == null) return null;
  try {
    final uri = base.resolve(_clean(raw));
    final web = uri.scheme == 'http' || uri.scheme == 'https';
    return web && uri.host.isNotEmpty ? uri : null;
  } on FormatException {
    return null;
  }
}

String _clean(String? raw) {
  if (raw == null) return '';
  return raw
      .replaceAllMapped(_entity, (m) {
        final e = m.group(1)!;
        if (e.startsWith('#')) {
          final code = e.startsWith('#x')
              ? int.tryParse(e.substring(2), radix: 16)
              : int.tryParse(e.substring(1));
          final ok =
              code != null &&
              code >= 32 &&
              code <= 0x10FFFF &&
              !(code >= 0xD800 && code <= 0xDFFF);
          return ok ? String.fromCharCode(code) : '';
        }
        return switch (e) {
          'amp' => '&',
          'lt' => '<',
          'gt' => '>',
          'quot' => '"',
          'apos' => "'",
          'nbsp' => ' ',
          _ => m.group(0)!,
        };
      })
      .replaceAll('<', '')
      .replaceAll('>', '')
      .replaceAll(_controls, ' ')
      .replaceAll(_spaces, ' ')
      .trim();
}

String _cap(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';
