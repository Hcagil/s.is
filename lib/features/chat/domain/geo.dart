/// A point on the earth.
final class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  /// The latitude.
  final double lat;

  /// The longitude.
  final double lng;

  @override
  bool operator ==(Object other) {
    return other is GeoPoint && other.lat == lat && other.lng == lng;
  }

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

/// A place found by name or by address: where it is, what it is called and its address (empty when unknown).
final class Place {
  const Place({required this.point, required this.name, this.address = ''});

  /// The place's location.
  final GeoPoint point;

  /// The place's name.
  final String name;

  /// The place's address.
  final String address;

  @override
  bool operator ==(Object other) {
    return other is Place &&
        other.point == point &&
        other.name == name &&
        other.address == address;
  }

  @override
  int get hashCode => Object.hash(point, name, address);
}

/// One line of search results before the place is chosen: [id] is what PlaceSearch.resolve needs; [name] is the place's name, [address] the rest of its address.
final class PlaceSuggestion {
  const PlaceSuggestion({
    required this.id,
    required this.name,
    this.address = '',
  });

  /// The place's ID.
  final String id;

  /// The place's name.
  final String name;

  /// The place's address.
  final String address;

  @override
  bool operator ==(Object other) {
    return other is PlaceSuggestion &&
        other.id == id &&
        other.name == name &&
        other.address == address;
  }

  @override
  int get hashCode => Object.hash(id, name, address);
}

/// A position fix from the phone: the point and how far off it may be, in metres.
final class LocationFix {
  const LocationFix(this.point, this.accuracyMeters);

  /// The location's point.
  final GeoPoint point;

  /// The accuracy in metres.
  final double accuracyMeters;

  @override
  bool operator ==(Object other) {
    return other is LocationFix &&
        other.point == point &&
        other.accuracyMeters == accuracyMeters;
  }

  @override
  int get hashCode => Object.hash(point, accuracyMeters);
}

/// What a map view is asked to show. The map looks at [target] (it moves there whenever [target] changes), at [zoom]. [me] is drawn as the blue dot of where the member is. When [interactive] is false the map cannot be moved (a chat bubble's preview). [onMoveStart] runs when the member starts moving the map, [onCenterChanged] with the map's centre when it comes to rest after being moved by the member (not after it moved itself to [target]). Callbacks use `void Function()` / `void Function(GeoPoint)` (no Flutter types).
final class MapViewSpec {
  const MapViewSpec({
    required this.target,
    this.zoom = 15,
    this.me,
    this.interactive = true,
    this.onMoveStart,
    this.onCenterChanged,
  });

  /// The target point to look at.
  final GeoPoint target;

  /// The zoom level.
  final double zoom;

  /// The member's location.
  final GeoPoint? me;

  /// Whether the map can be moved by the member.
  final bool interactive;

  /// Called when the member starts moving the map.
  final void Function()? onMoveStart;

  /// Called with the map's centre when it comes to rest after the member moved it.
  final void Function(GeoPoint center)? onCenterChanged;
}
