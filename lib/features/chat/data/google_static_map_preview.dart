import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../domain/geo.dart';
import 'maps_request_headers.dart';

/// The map picture of a location bubble: a Google Static Maps image (centre =
/// the point, zoom 15) fetched once and kept in memory only (Maps Platform
/// terms forbid storing the images on disk); while it loads or when it cannot be fetched the picture area is a
/// plain light-grey fill.
class GoogleStaticMapPreview extends StatefulWidget {
  /// Creates a static map preview widget.
  const GoogleStaticMapPreview({
    super.key,
    required this.point,
    required this.apiKey,
    required this.client,
  });

  /// The point to centre the map on.
  final GeoPoint point;

  /// The Google Maps API key.
  final String apiKey;

  /// The HTTP client to use for requests.
  final http.Client client;

  @override
  State<GoogleStaticMapPreview> createState() => _GoogleStaticMapPreviewState();
}

class _GoogleStaticMapPreviewState extends State<GoogleStaticMapPreview> {
  static final Map<String, Uint8List> _memory = {};
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant GoogleStaticMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.point != widget.point) {
      _bytes = _load();
    }
  }

  Future<Uint8List?> _load() async {
    final lat = widget.point.lat;
    final lng = widget.point.lng;
    final key =
        'static_map_${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}';
    final cached = _memory[key];
    if (cached != null) return cached;
    try {
      final r = await widget.client
          .get(
            Uri.https('maps.googleapis.com', '/maps/api/staticmap', {
              'center': '$lat,$lng',
              'zoom': '15',
              'size': '238x84',
              'scale': '2',
              'maptype': 'roadmap',
              'key': widget.apiKey,
            }),
            headers: mapsRequestHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200 ||
          !(r.headers['content-type'] ?? '').startsWith('image/')) {
        return null;
      }
      _memory[key] = r.bodyBytes;
      return r.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) {
        final b = snap.data;
        if (b == null) {
          return const ColoredBox(
            color: Color(0xFFE5E3DF),
            child: SizedBox.expand(),
          );
        }
        return Image.memory(
          b,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        );
      },
    );
  }
}
