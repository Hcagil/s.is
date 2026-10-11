/// A site whose videos play inside the chat.
enum VideoSite {
  /// YouTube.
  youtube,

  /// Instagram.
  instagram,

  /// TikTok.
  tiktok,

  /// X (Twitter).
  x,
}

/// The site's name as people read it.
extension VideoSiteLabel on VideoSite {
  /// The name of the video site.
  String get label => switch (this) {
    VideoSite.youtube => 'YouTube',
    VideoSite.instagram => 'Instagram',
    VideoSite.tiktok => 'TikTok',
    VideoSite.x => 'X',
  };
}

/// A link turned into the site's official embed page.
final class VideoEmbed {
  /// Creates a video embed.
  const VideoEmbed({
    required this.site,
    required this.link,
    required this.url,
    this.referer,
  });

  /// The site of the video.
  final VideoSite site;

  /// The link in the message.
  final Uri link;

  /// The official embed page to load.
  final Uri url;

  /// Referer header value for the first request, null = none.
  final String? referer;
}

/// Whether [host] is [d] or a subdomain of it.
bool _on(String host, String d) => host == d || host.endsWith('.$d');

/// The official embed page for [link], or null when [link] is not a video
/// we can play inside the app (other site, or a link without a video id).
VideoEmbed? videoEmbedFor(Uri link) {
  if (link.scheme != 'https' && link.scheme != 'http') return null;
  final host = link.host.toLowerCase();
  if (_on(host, 'youtube.com') ||
      host == 'youtu.be' ||
      _on(host, 'youtube-nocookie.com')) {
    return _youtube(link, host);
  }
  if (_on(host, 'instagram.com')) return _instagram(link);
  if (_on(host, 'tiktok.com')) return _tiktok(link);
  if (_on(host, 'x.com') || _on(host, 'twitter.com')) return _x(link);
  return null;
}

final _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');

VideoEmbed? _youtube(Uri link, String host) {
  final s = link.pathSegments;
  final String? id;
  if (host == 'youtu.be') {
    id = s.isEmpty ? null : s.first;
  } else if (s.length >= 2 && const ['shorts', 'embed', 'live'].contains(s[0])) {
    id = s[1];
  } else if (s.length == 1 && s[0] == 'watch') {
    id = link.queryParameters['v'];
  } else {
    id = null;
  }
  if (id == null || !_youtubeId.hasMatch(id)) return null;
  return VideoEmbed(
    site: VideoSite.youtube,
    link: link,
    url: Uri.https('www.youtube-nocookie.com', '/embed/$id', {
      'playsinline': '1',
      'autoplay': '1',
      'rel': '0',
    }),
    referer: 'https://com.esd.sis',
  );
}

final _instagramPath = RegExp(r'^[A-Za-z0-9_-]{5,}$');
final _tiktokPath = RegExp(r'^\d{6,25}$');
final _xPath = RegExp(r'^\d{1,25}$');

VideoEmbed? _instagram(Uri link) {
  final s = link.pathSegments;
  int? i;
  for (int j = 0; j < s.length; j++) {
    if (const ['p', 'reel', 'reels', 'tv'].contains(s[j]) &&
        j + 1 < s.length &&
        _instagramPath.hasMatch(s[j + 1])) {
      i = j;
      break;
    }
  }
  if (i == null) return null;
  final kind = s[i] == 'reels' ? 'reel' : s[i];
  final code = s[i + 1];
  final url = Uri.https('www.instagram.com', '/$kind/$code/embed/');
  return VideoEmbed(
    site: VideoSite.instagram,
    link: link,
    url: url,
  );
}

VideoEmbed? _tiktok(Uri link) {
  final s = link.pathSegments;
  int? i;
  for (int j = 0; j < s.length; j++) {
    if (s[j] == 'video' &&
        j + 1 < s.length &&
        _tiktokPath.hasMatch(s[j + 1])) {
      i = j;
      break;
    }
  }
  if (i == null) return null;
  final url = Uri.https('www.tiktok.com', '/player/v1/${s[i + 1]}', {'autoplay': '1'});
  return VideoEmbed(
    site: VideoSite.tiktok,
    link: link,
    url: url,
  );
}

VideoEmbed? _x(Uri link) {
  final s = link.pathSegments;
  if (s.length < 3 || s[1] != 'status' || !_xPath.hasMatch(s[2])) return null;
  final url = Uri.https('platform.twitter.com', '/embed/Tweet.html', {'id': s[2]});
  return VideoEmbed(
    site: VideoSite.x,
    link: link,
    url: url,
  );
}

/// Whether [embed] allows [target] to load in frame [mainFrame].
bool videoEmbedAllows(VideoEmbed embed, Uri target, {required bool mainFrame}) {
  if (target.scheme != 'https') return false;
  final host = target.host.toLowerCase();
  final domains = switch (embed.site) {
    VideoSite.youtube => ['youtube-nocookie.com', 'youtube.com'],
    VideoSite.instagram => ['instagram.com'],
    VideoSite.tiktok => ['tiktok.com'],
    VideoSite.x => ['twitter.com', 'x.com'],
  };
  if (!domains.any((d) => _on(host, d))) return false;
  if (!mainFrame) return true;

  final prefix = switch (embed.site) {
    VideoSite.youtube => '/embed/',
    VideoSite.instagram => '/${embed.url.pathSegments.first}/',
    VideoSite.tiktok => '/player/v1/',
    VideoSite.x => '/embed/',
  };
  return target.path.startsWith(prefix);
}

/// Why a site would not show a video.
enum VideoRefusal {
  /// The video is private.
  isPrivate,

  /// The video was deleted.
  deleted,

  /// The video is not available in the region.
  region,

  /// Login required.
  login,

  /// Other reason.
  other,
}

/// Converts a status code to a refusal reason.
VideoRefusal refusalForStatus(int status) => switch (status) {
  401 => VideoRefusal.login,
  403 => VideoRefusal.isPrivate,
  404 || 410 => VideoRefusal.deleted,
  451 => VideoRefusal.region,
  _ => VideoRefusal.other,
};

/// What the player sheet gives the data layer to show one embed.
final class VideoEmbedViewSpec {
  /// Creates a video embed view spec.
  const VideoEmbedViewSpec({
    required this.embed,
    required this.onLoaded,
    required this.onRefused,
    required this.onExternal,
  });

  /// The video embed to show.
  final VideoEmbed embed;

  /// Called when the page finished loading.
  final void Function() onLoaded;

  /// Called when the page could not be shown.
  final void Function(VideoRefusal) onRefused;

  /// Called with a link outside the allowlist that the page tried to open.
  final void Function(Uri) onExternal;
}
