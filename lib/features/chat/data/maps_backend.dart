import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../domain/geo.dart';
import '../domain/location_services.dart';
import 'google_map_view.dart';
import 'google_place_search.dart';
import 'google_static_map_preview.dart';
import 'no_place_search.dart';
import 'osm_map_view.dart';

/// The map pieces the chat uses, Google when a key was built in, else
/// OpenStreetMap.
final class MapsBackend {
  /// Picks Google Maps when [apiKey] is not empty, else OpenStreetMap (no
  /// place search).
  MapsBackend({
    required String apiKey,
    required http.Client client,
    String languageCode = 'en',
  }) : _apiKey = apiKey,
       _client = client,
       usesGoogle = apiKey.isNotEmpty,
       placeSearch = apiKey.isNotEmpty
           ? GooglePlaceSearch(apiKey, client, languageCode: languageCode)
           : const NoPlaceSearch();

  final String _apiKey;
  final http.Client _client;

  /// True when Google Maps is used.
  final bool usesGoogle;

  /// The place search: Google Places, or one that finds nothing.
  final PlaceSearch placeSearch;

  /// A map the member can move.
  Widget mapView(MapViewSpec spec) =>
      usesGoogle ? googleMapView(spec) : osmMapView(spec);

  /// The small picture inside a location bubble.
  Widget mapPreview(GeoPoint point) => usesGoogle
      ? GoogleStaticMapPreview(point: point, apiKey: _apiKey, client: _client)
      : osmMapPreview(point);
}
