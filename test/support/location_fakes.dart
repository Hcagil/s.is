// Fakes for location services, place search, maps opener and location share
// derived from the corresponding domain interfaces (not from any implementation).
// They can be held mid-call with a gate, like the real platform prompt and network.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/location_services.dart';
import 'package:sis/features/chat/domain/location_share_repository.dart';
import 'package:sis/features/chat/domain/geo.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:sis/features/chat/presentation/map_providers.dart';

/// The device's location provider. [granted] is what [hasPermission] answers;
/// it never prompts. [answer] decides what [current] returns. When [gate] is
/// set, [current] awaits it (simulating a slow GPS).
class FakeDeviceLocation implements DeviceLocation {
  FakeDeviceLocation({
    this.granted = false,
    this.answer = const Ok(LocationFix(GeoPoint(41.0, 29.0), 12)),
  });

  bool granted;
  Result<LocationFix> answer;
  Completer<void>? gate;

  int hasPermissionCalls = 0;
  int currentCalls = 0;

  @override
  Future<bool> hasPermission() async {
    hasPermissionCalls++;
    return granted;
  }

  @override
  Future<Result<LocationFix>> current() async {
    currentCalls++;
    if (gate != null) await gate!.future;
    if (answer is Ok) granted = true;
    return answer;
  }
}

/// The place search provider. It records every query, can hold calls
/// until [reply] is called, and can simulate offline errors.
class FakePlaceSearch implements PlaceSearch {
  FakePlaceSearch({this.canSearch = true});

  @override
  final bool canSearch;

  final queries = <String>[];
  final results = <String, List<PlaceSuggestion>>{};
  bool hold = false;
  final _pending = <MapEntry<String, Completer<void>>>[];

  @override
  Future<Result<List<PlaceSuggestion>>> suggest(
    String query, {
    GeoPoint? near,
  }) async {
    queries.add(query);
    if (hold) {
      final c = Completer<void>();
      _pending.add(MapEntry(query, c));
      await c.future;
    }
    return Ok(results[query] ?? const []);
  }

  /// Completes the first pending request for [query].
  void reply(String query) {
    final index = _pending.indexWhere((e) => e.key == query);
    if (index != -1) {
      final entry = _pending.removeAt(index);
      entry.value.complete();
    }
  }

  final places = <String, Place>{};
  final resolved = <PlaceSuggestion>[];

  @override
  Future<Result<Place>> resolve(PlaceSuggestion suggestion) async {
    resolved.add(suggestion);
    final p = places[suggestion.id];
    return p == null
        ? const Err(NetworkFailure('offline', retryable: true))
        : Ok(p);
  }

  Place? Function(GeoPoint) reverseAnswer = (p) =>
      Place(point: p, name: 'Pin street 1', address: 'Kadikoy, Istanbul');

  final reversed = <GeoPoint>[];

  /// How long the address lookup of a point takes, like a real network
  /// round trip; answers can arrive out of order.
  Duration Function(GeoPoint) reverseDelay = (_) => Duration.zero;

  @override
  Future<Result<Place?>> reverse(GeoPoint point) async {
    reversed.add(point);
    final delay = reverseDelay(point);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return Ok(reverseAnswer(point));
  }
}

/// The maps opener. Records every open request.
class FakeMapsOpener implements MapsOpener {
  bool answer = true;
  final opened = <(GeoPoint, String)>[];

  @override
  Future<bool> open(GeoPoint point, String label) async {
    opened.add((point, label));
    return answer;
  }
}

/// The location share repository. Records every send call and can be
/// held mid-call with a gate.
class FakeLocationShare implements LocationShareRepository {
  final calls = <(String, String, SharedLocation)>[];
  Result<void> answer = const Ok(null);
  Completer<void>? gate;

  @override
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    SharedLocation location,
  ) async {
    calls.add((conversationId, messageId, location));
    if (gate != null) await gate!.future;
    return answer;
  }
}

/// The movable map. Keeps the last spec so a test can play the member's drag
/// through its callbacks, as the real map widget would.
class FakeMap {
  MapViewSpec? last;

  Widget build(MapViewSpec spec) {
    last = spec;
    return const SizedBox.expand(key: ValueKey('test-map'));
  }

  /// The member drags the map so [to] is under the pin.
  void drag(GeoPoint to) {
    last!.onMoveStart?.call();
    last!.onCenterChanged?.call(to);
  }
}

/// Convenience overrides for tests.
List<Override> locationOverrides({
  FakeDeviceLocation? device,
  FakePlaceSearch? search,
  FakeMapsOpener? opener,
  FakeLocationShare? share,
  FakeMap? map,
}) => [
  deviceLocationProvider.overrideWithValue(device ?? FakeDeviceLocation()),
  placeSearchProvider.overrideWithValue(search ?? FakePlaceSearch()),
  mapsOpenerProvider.overrideWithValue(opener ?? FakeMapsOpener()),
  locationShareRepositoryProvider.overrideWithValue(
    share ?? FakeLocationShare(),
  ),
  mapViewProvider.overrideWithValue((map ?? FakeMap()).build),
  mapPreviewProvider.overrideWithValue(
    (point) => SizedBox(
      key: ValueKey('test-preview-${point.lat},${point.lng}'),
      height: 120,
    ),
  ),
];
