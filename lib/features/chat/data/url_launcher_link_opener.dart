import 'package:url_launcher/url_launcher.dart';

import '../domain/links.dart';

/// [LinkOpener] that hands links to the phone's browser.
final class UrlLauncherLinkOpener implements LinkOpener {
  const UrlLauncherLinkOpener();

  @override
  Future<bool> open(Uri link) async {
    // linkSegments only yields http(s); checked again at the boundary.
    if (link.scheme != 'http' && link.scheme != 'https') return false;
    try {
      return await launchUrl(link, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
