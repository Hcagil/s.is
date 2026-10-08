import '../../../core/failure.dart';
import 'geo.dart';

/// The phone's own position. Foreground only ("while in use"); a repository never throws.
abstract interface class DeviceLocation {
  /// Whether the member already allowed location, WITHOUT asking.
  Future<bool> hasPermission();

  /// One position fix. Asks for permission the first time it is needed. Err(LocationDeniedFailure) when permission is refused (forever: true when the member must change it in the phone settings), Err(LocationUnavailableFailure) when location is switched off on the phone or no fix arrives in time.
  Future<Result<LocationFix>> current();
}

/// Finds places by name and addresses by point. canSearch is false when the app has no search service (then suggest/resolve are never called).
abstract interface class PlaceSearch {
  /// Whether searching by name is available.
  bool get canSearch;

  /// Suggestions for [query] (typed so far), biased towards [near] when given. A search session for billing starts with the first call and ends with [resolve].
  Future<Result<List<PlaceSuggestion>>> suggest(String query, {GeoPoint? near});

  /// The full place (point, name, address) for a chosen suggestion; ends the search session.
  Future<Result<Place>> resolve(PlaceSuggestion suggestion);

  /// The address at [point]: a Place whose point is [point], or null when none is known (or this service cannot look it up).
  Future<Result<Place?>> reverse(GeoPoint point);
}

/// Opens a point in the phone's maps app.
abstract interface class MapsOpener {
  /// Opens [point] with [label] in the phone's maps app. False when no app could open it. Never throws.
  Future<bool> open(GeoPoint point, String label);
}
