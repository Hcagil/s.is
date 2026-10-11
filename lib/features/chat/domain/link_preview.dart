import 'dart:typed_data';

/// The card a link message carries: what the sender's phone read from the
/// page once, so readers never contact the website.
final class LinkPreview {
  /// Creates a link preview.
  const LinkPreview({
    required this.url,
    required this.title,
    this.description,
    this.site,
    this.imagePath,
    this.video = false,
  });

  /// The link that was previewed; always http or https.
  final Uri url;

  /// Title of the page (1 to [maxTitle] characters).
  final String title;

  /// Description of the page, at most [maxDescription] characters.
  final String? description;

  /// Name of the site, at most [maxSite] characters.
  final String? site;

  /// Storage path of the card picture in the link-previews bucket.
  final String? imagePath;

  /// The link is on a video site: the card shows a play mark.
  final bool video;

  /// Longest title the server accepts.
  static const maxTitle = 200;

  /// Longest description the server accepts.
  static const maxDescription = 400;

  /// Longest site name the server accepts.
  static const maxSite = 100;

  /// A copy with [imagePath] replaced (null removes the picture).
  LinkPreview withImagePath(String? path) => LinkPreview(
    url: url,
    title: title,
    description: description,
    site: site,
    imagePath: path,
    video: video,
  );

  /// The JSON stored in `messages.link_preview`.
  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'title': title,
    'description': ?description,
    'site': ?site,
    'image': ?imagePath,
    if (video) 'video': true,
  };

  /// The card in [json], or null when it is not a valid card (never throws).
  static LinkPreview? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'];
    final title = json['title'];
    final description = json['description'];
    final site = json['site'];
    final image = json['image'];
    final video = json['video'];
    if (url is! String || title is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    if (title.isEmpty || title.length > maxTitle) return null;
    if (description != null &&
        (description is! String || description.length > maxDescription)) {
      return null;
    }
    if (site != null && (site is! String || site.length > maxSite)) {
      return null;
    }
    if (image != null && image is! String) return null;
    if (video != null && video is! bool) return null;
    return LinkPreview(
      url: uri,
      title: title,
      description: description as String?,
      site: site as String?,
      imagePath: image as String?,
      video: video as bool? ?? false,
    );
  }
}

/// A card ready to send: the data and the picture to upload with it.
final class LinkPreviewDraft {
  /// Creates a draft.
  const LinkPreviewDraft({required this.preview, this.image});

  /// The card data.
  final LinkPreview preview;

  /// JPEG bytes of the card picture, at most 262144 bytes; null: no picture.
  final Uint8List? image;

  /// A copy whose card points at [path] (where the picture will be stored).
  LinkPreviewDraft withImagePath(String path) =>
      LinkPreviewDraft(preview: preview.withImagePath(path), image: image);
}

/// Where the card picture of message [messageId] lives in the link-previews
/// bucket; the first segment is the conversation, as for attachments.
String linkImagePath(String conversationId, String messageId) =>
    '$conversationId/$messageId.jpg';

/// Whether [url] is on a video site (the card then shows a play mark).
bool isVideoHost(Uri url) {
  final host = url.host.toLowerCase();
  return const [
    'youtube.com',
    'youtu.be',
    'instagram.com',
    'tiktok.com',
    'x.com',
    'twitter.com',
  ].any((d) => host == d || host.endsWith('.$d'));
}

/// The host of [url] in ASCII, so a lookalike domain can never pass for the
/// real one: a label with non-ASCII letters shows as its xn-- form.
String displayHost(Uri url) {
  // Dart keeps a non-ASCII host percent-encoded; decode it to see the letters.
  String host;
  try {
    host = Uri.decodeComponent(url.host);
  } on FormatException {
    host = url.host;
  }
  return host.toLowerCase().split('.').map(_punycode).join('.');
}

/// What a bubble shows for [url]: the host and the start of the path.
String shortLink(Uri url) {
  final host = displayHost(url);
  final path = url.path;
  final full =
      (host.startsWith('www.') ? host.substring(4) : host) +
      (path.isEmpty || path == '/' ? '' : path);
  return full.length <= 40 ? full : '${full.substring(0, 39)}…';
}

// RFC 3492 (Punycode), encoding only.
String _punycode(String label) {
  if (label.runes.every((r) => r < 128)) return label;
  final input = label.runes.toList();
  final output = StringBuffer();
  var b = 0;
  for (final r in input) {
    if (r < 128) {
      output.writeCharCode(r);
      b++;
    }
  }
  if (b > 0) output.write('-');
  var h = b;
  var n = 128;
  var delta = 0;
  var bias = 72;
  while (h < input.length) {
    var m = 0x7fffffff;
    for (final r in input) {
      if (r >= n && r < m) m = r;
    }
    delta += (m - n) * (h + 1);
    n = m;
    for (final r in input) {
      if (r < n) delta++;
      if (r == n) {
        var q = delta;
        for (var k = 36; ; k += 36) {
          final t = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias);
          if (q < t) break;
          output.write(_digit(t + (q - t) % (36 - t)));
          q = (q - t) ~/ (36 - t);
        }
        output.write(_digit(q));
        bias = _adapt(delta, h + 1, h == b);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return 'xn--$output';
}

int _adapt(int delta, int numPoints, bool firstTime) {
  var d = firstTime ? delta ~/ 700 : delta ~/ 2;
  d += d ~/ numPoints;
  var k = 0;
  while (d > (35 * 26) ~/ 2) {
    d = d ~/ 35;
    k += 36;
  }
  return k + (36 * d) ~/ (d + 38);
}

String _digit(int d) =>
    String.fromCharCode(d < 26 ? 0x61 + d : 0x30 + (d - 26));
