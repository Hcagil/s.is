import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

import '../domain/geo.dart';
import '../domain/location_services.dart';

/// [MapsOpener] that hands a point to the phone's maps app.
final class UrlLauncherMapsOpener implements MapsOpener {
  const UrlLauncherMapsOpener();

  @override
  Future<bool> open(GeoPoint point, String label) async {
    final lat = point.lat.toStringAsFixed(6);
    final lng = point.lng.toStringAsFixed(6);
    final Uri uri;
    if (Platform.isAndroid) {
      // encodeComponent leaves ( and ) alone, but they close the geo: label.
      final name = Uri.encodeComponent(label)
          .replaceAll('(', '%28')
          .replaceAll(')', '%29');
      uri = Uri.parse('geo:$lat,$lng?q=$lat,$lng($name)');
    } else {
      uri = Uri.https('maps.apple.com', '/', {'ll': '$lat,$lng', 'q': label});
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
