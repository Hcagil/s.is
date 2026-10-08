import '../../../core/failure.dart';
import '../domain/geo.dart';
import '../domain/location_services.dart';

/// [PlaceSearch] for a build with no search service (no Google Maps key): OpenStreetMap's public Nominatim service forbids search-as-you-type and cannot be switched off without an app update, so there is no search and no address lookup; the pin screen shows coordinates.
final class NoPlaceSearch implements PlaceSearch {
  const NoPlaceSearch();

  @override
  bool get canSearch => false;

  @override
  Future<Result<List<PlaceSuggestion>>> suggest(
    String query, {
    GeoPoint? near,
  }) => Future.value(const Ok(<PlaceSuggestion>[]));

  @override
  Future<Result<Place>> resolve(PlaceSuggestion suggestion) =>
      Future.value(const Err(NetworkFailure('Place search is not available.')));

  @override
  Future<Result<Place?>> reverse(GeoPoint point) =>
      Future.value(const Ok(null));
}
