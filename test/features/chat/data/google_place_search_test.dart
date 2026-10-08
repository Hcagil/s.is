import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/features/chat/data/google_place_search.dart';
import 'package:sis/features/chat/data/maps_backend.dart';
import 'package:sis/features/chat/data/maps_request_headers.dart';
import 'package:sis/features/chat/domain/geo.dart';
import 'package:sis/core/failure.dart';

String? tokenOf(http.Request r) {
  final token = r.url.queryParameters['sessionToken'];
  if (token != null) return token;
  if (r.body.isEmpty) return null;
  final body = jsonDecode(r.body) as Map<String, dynamic>;
  return body['sessionToken'] as String?;
}

String? h(http.Request r, String name) {
  return r.headers.entries
      .firstWhere(
        (e) => e.key.toLowerCase() == name.toLowerCase(),
        orElse: () => MapEntry('', ''),
      )
      .value;
}

void hasAppHeaders(http.Request r) {
  for (final entry in mapsRequestHeaders().entries) {
    expect(r.headers[entry.key], entry.value);
  }
}

http.Response _autocompleteResponse() {
  final body = {
    "suggestions": [
      {
        "placePrediction": {
          "placeId": "ChIJ1",
          "text": {"text": "Moda Cd. 12, Kadikoy, Istanbul"},
          "structuredFormat": {
            "mainText": {"text": "Moda Cd. 12"},
            "secondaryText": {"text": "Kadikoy, Istanbul"},
          },
        },
      },
    ],
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _detailsResponse() {
  final body = {
    "id": "ChIJ1",
    "location": {"latitude": 40.987, "longitude": 29.027},
    "formattedAddress": "Moda Cd. 12, Kadikoy, Istanbul",
    "displayName": {"text": "Moda Cd. 12"},
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _geocodeResponse() {
  final body = {
    "status": "OK",
    "results": [
      {
        "formatted_address": "Moda Cd. 12, 34710 Kadikoy/Istanbul",
        "geometry": {
          "location": {"lat": 41.0, "lng": 29.0},
        },
      },
    ],
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _zeroResultsResponse() {
  final body = {"status": "ZERO_RESULTS", "results": []};
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _errorResponse() {
  final body = {
    "error": {"code": 403},
  };
  return http.Response(
    jsonEncode(body),
    403,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

T ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>());
  return (r as Ok<T>).value;
}

Failure err<T>(Result<T> r) {
  expect(r, isA<Err<T>>());
  return (r as Err<T>).failure;
}

void main() {
  group('GooglePlaceSearch', () {
    test('suggest posts an autocomplete with key, input, language and a session token', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request req) async {
        requests.add(req);
        return _autocompleteResponse();
      });

      final search = GooglePlaceSearch('test-key', client, languageCode: 'tr');
      final result = await search.suggest('moda', near: GeoPoint(41, 29));

      expect(requests.length, 1);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(
        req.url.toString(),
        'https://places.googleapis.com/v1/places:autocomplete',
      );
      expect(h(req, 'X-Goog-Api-Key'), 'test-key');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['input'], 'moda');
      expect(body['languageCode'], 'tr');
      expect(tokenOf(req), isNotNull);
      hasAppHeaders(req);
      final suggestions = ok(result);
      expect(suggestions.length, 1);
      final s = suggestions.first;
      expect(s.id, 'ChIJ1');
      expect(s.name, 'Moda Cd. 12');
      expect(s.address, 'Kadikoy, Istanbul');
    });

    test(
      'the session token is reused across keystrokes and closed by resolve',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((http.Request req) async {
          requests.add(req);
          if (req.url.path.endsWith(':autocomplete')) {
            return _autocompleteResponse();
          } else if (req.url.path.startsWith('/v1/places/')) {
            return _detailsResponse();
          }
          return http.Response('Not Found', 404);
        });

        final search = GooglePlaceSearch(
          'test-key',
          client,
          languageCode: 'tr',
        );

        await search.suggest('m');
        final r2 = await search.suggest('mo');
        final token1 = tokenOf(requests[0]);
        final token2 = tokenOf(requests[1]);
        expect(token1, isNotNull);
        expect(token2, isNotNull);
        expect(token1, equals(token2));

        final suggestion = ok(r2).first;
        final resolveResult = await search.resolve(suggestion);
        final place = ok(resolveResult);
        expect(place.point, GeoPoint(40.987, 29.027));
        expect(place.name, 'Moda Cd. 12');
        expect(place.address, isNotEmpty);

        final tokenDetails = tokenOf(requests[2]);
        expect(tokenDetails, equals(token1));

        await search.suggest('k');
        final token3 = tokenOf(requests[3]);
        expect(token3, isNotNull);
        expect(token3, isNot(token1));

        // Verify details request headers
        final detailsReq = requests[2];
        expect(detailsReq.method, 'GET');
        expect(detailsReq.url.host, 'places.googleapis.com');
        expect(detailsReq.url.path, '/v1/places/ChIJ1');
        expect(h(detailsReq, 'X-Goog-Api-Key'), 'test-key');
        final fieldMask = h(detailsReq, 'X-Goog-FieldMask');
        expect(fieldMask, isNotNull);
        expect(fieldMask!.contains('location'), true);
        expect(fieldMask.contains('*'), false);
        hasAppHeaders(detailsReq);
      },
    );

    test('reverse asks Geocoding for the point', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request req) async {
        requests.add(req);
        return _geocodeResponse();
      });

      final search = GooglePlaceSearch('test-key', client, languageCode: 'tr');
      final result = await search.reverse(GeoPoint(41.0, 29.0));

      expect(requests.length, 1);
      final req = requests.single;
      expect(req.method, 'GET');
      expect(req.url.host, 'maps.googleapis.com');
      expect(req.url.path, '/maps/api/geocode/json');
      final latlng = req.url.queryParameters['latlng'];
      expect(latlng, isNotNull);
      final parts = latlng!.split(',');
      expect(double.parse(parts[0]), 41.0);
      expect(double.parse(parts[1]), 29.0);
      // key can be in query or header
      final keyInQuery = req.url.queryParameters['key'];
      final keyInHeader = h(req, 'X-Goog-Api-Key');
      expect(keyInQuery ?? keyInHeader, 'test-key');
      hasAppHeaders(req);
      final place = ok(result);
      expect(place, isNotNull);
      expect(place!.name, isNotEmpty);
    });

    test('reverse with no result is Ok(null)', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request req) async {
        requests.add(req);
        return _zeroResultsResponse();
      });

      final search = GooglePlaceSearch('test-key', client, languageCode: 'tr');
      final result = await search.reverse(GeoPoint(41.0, 29.0));
      expect(ok(result), isNull);
    });

    test('offline is a retryable network failure, never a throw', () async {
      final client = MockClient((http.Request req) async {
        throw http.ClientException('offline');
      });

      final search = GooglePlaceSearch('test-key', client, languageCode: 'tr');

      final suggestResult = await search.suggest('moda');
      expect(err(suggestResult), isA<NetworkFailure>());
      expect((err(suggestResult) as NetworkFailure).retryable, true);

      final resolveResult = await search.resolve(
        PlaceSuggestion(id: 'x', name: 'X', address: ''),
      );
      expect(err(resolveResult), isA<NetworkFailure>());

      final reverseResult = await search.reverse(GeoPoint(41.0, 29.0));
      expect(err(reverseResult), isA<NetworkFailure>());
    });

    test('a refused key is a failure, not a crash', () async {
      final client = MockClient((http.Request req) async {
        return _errorResponse();
      });

      final search = GooglePlaceSearch('test-key', client, languageCode: 'tr');
      final result = await search.suggest('moda');
      err(result);
    });

    test('the app ids are SIS', () {
      expect(mapsAndroidPackage, 'com.esd.sis');
      expect(mapsIosBundleId, 'com.esd.sis');
    });

    test('MapsBackend without a key has no search', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request req) async {
        requests.add(req);
        return http.Response('ok', 200);
      });

      final backend = MapsBackend(apiKey: '', client: client);
      expect(backend.usesGoogle, false);
      expect(backend.placeSearch.canSearch, false);
      expect(requests.isEmpty, true);

      final backendWithKey = MapsBackend(apiKey: 'k', client: client);
      expect(backendWithKey.usesGoogle, true);
      expect(backendWithKey.placeSearch, isA<GooglePlaceSearch>());
      expect(backendWithKey.placeSearch.canSearch, true);
    });
  });
}
