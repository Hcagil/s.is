import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/geo.dart';
import '../domain/location_services.dart';
import '../domain/message.dart' show randomMessageId;
import 'maps_request_headers.dart';

/// [PlaceSearch] backed by Google Places API (New) over REST (Autocomplete with a session token, then Place Details with Essentials fields only) and the Geocoding API for the address of a dropped pin.
final class GooglePlaceSearch implements PlaceSearch {
  GooglePlaceSearch(this._key, this._client, {this.languageCode = 'en'});

  final String _key;
  final http.Client _client;

  /// The language results are written in.
  final String languageCode;
  String? _session;

  @override
  bool get canSearch => true;

  Map<String, String> get _headers => {
    ...mapsRequestHeaders(),
    'X-Goog-Api-Key': _key,
  };

  Future<Object?> _json(http.Response r) async {
    if (r.statusCode != 200) {
      throw StateError('Maps request failed: ${r.statusCode}');
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  @override
  Future<Result<List<PlaceSuggestion>>> suggest(
    String query, {
    GeoPoint? near,
  }) async {
    if (query.trim().isEmpty) {
      return const Ok(<PlaceSuggestion>[]);
    }
    try {
      _session ??= randomMessageId();
      final body = {
        'input': query.trim(),
        'sessionToken': _session,
        'languageCode': languageCode,
        if (near != null)
          'locationBias': {
            'circle': {
              'center': {'latitude': near.lat, 'longitude': near.lng},
              'radius': 50000.0,
            },
          },
      };
      final r = await _client
          .post(
            Uri.https('places.googleapis.com', '/v1/places:autocomplete'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      final json = await _json(r) as Map<String, dynamic>;
      final list = <PlaceSuggestion>[];
      for (final entry in json['suggestions'] as List<dynamic>? ?? const []) {
        final p =
            (entry as Map<String, dynamic>)['placePrediction']
                as Map<String, dynamic>?;
        if (p == null || p['placeId'] is! String) continue;
        final format = p['structuredFormat'] as Map<String, dynamic>?;
        final name =
            ((format?['mainText'] as Map<String, dynamic>?)?['text'] ??
                    (p['text'] as Map<String, dynamic>?)?['text'] ??
                    '')
                as String;
        if (name.isEmpty) continue;
        final address =
            ((format?['secondaryText'] as Map<String, dynamic>?)?['text'] ?? '')
                as String;
        list.add(
          PlaceSuggestion(
            id: p['placeId'] as String,
            name: name,
            address: address,
          ),
        );
      }
      return Ok(list);
    } catch (e) {
      return Err(readableFailure(e));
    }
  }

  @override
  Future<Result<Place>> resolve(PlaceSuggestion suggestion) async {
    // The session ends with this call, whatever its answer.
    final session = _session;
    _session = null;
    try {
      final r = await _client
          .get(
            Uri.https('places.googleapis.com', '/v1/places/${suggestion.id}', {
              'languageCode': languageCode,
              'sessionToken': ?session,
            }),
            headers: {
              ..._headers,
              'X-Goog-FieldMask': 'formattedAddress,location',
            },
          )
          .timeout(const Duration(seconds: 10));
      final json = await _json(r) as Map<String, dynamic>;
      final loc = json['location'] as Map<String, dynamic>;
      return Ok(
        Place(
          point: GeoPoint(
            (loc['latitude'] as num).toDouble(),
            (loc['longitude'] as num).toDouble(),
          ),
          name: suggestion.name,
          address: json['formattedAddress'] as String? ?? suggestion.address,
        ),
      );
    } catch (e) {
      return Err(readableFailure(e));
    }
  }

  @override
  Future<Result<Place?>> reverse(GeoPoint point) async {
    try {
      final r = await _client
          .get(
            Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
              'latlng': '${point.lat},${point.lng}',
              'key': _key,
              'language': languageCode,
            }),
            headers: mapsRequestHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      final json = await _json(r) as Map<String, dynamic>;
      final status = json['status'] as String?;
      if (status == 'ZERO_RESULTS') return const Ok(null);
      if (status != 'OK') throw StateError('Geocoding failed: $status');
      final results = json['results'] as List<dynamic>;
      if (results.isEmpty) return const Ok(null);
      final formatted =
          (results.first as Map<String, dynamic>)['formatted_address']
              as String?;
      if (formatted == null || formatted.isEmpty) return const Ok(null);
      final comma = formatted.indexOf(',');
      final name = comma < 0 ? formatted : formatted.substring(0, comma).trim();
      final address = comma < 0 ? '' : formatted.substring(comma + 1).trim();
      return Ok(Place(point: point, name: name, address: address));
    } catch (e) {
      return Err(readableFailure(e));
    }
  }
}
