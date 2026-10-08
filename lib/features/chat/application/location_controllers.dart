part of 'chat_controllers.dart';

/// Sends a place as a message.
final locationShareRepositoryProvider = Provider<LocationShareRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// The phone's own position.
final deviceLocationProvider = Provider<DeviceLocation>(
  (_) => throw UnimplementedError('override in main'),
);

/// Finds places by name and addresses by point.
final placeSearchProvider = Provider<PlaceSearch>(
  (_) => throw UnimplementedError('override in main'),
);

/// Opens a point in the phone's maps app.
final mapsOpenerProvider = Provider<MapsOpener>(
  (_) => throw UnimplementedError('override in main'),
);

/// What the share page knows about permission.
enum LocationAccess { unknown, granted, denied, deniedForever, unavailable }

/// State of the location picker page.
final class LocationPickerState {
  const LocationPickerState({
    this.access = LocationAccess.unknown,
    this.me,
    this.center,
    this.address,
    this.suggestions = const [],
    this.searching = false,
  });

  /// What the share page knows about permission.
  final LocationAccess access;

  /// Last known fix of the phone.
  final LocationFix? me;

  /// The pin's point on the pick page.
  final GeoPoint? center;

  /// The address of [center] (null while unknown or when none).
  final Place? address;

  /// For the typed text.
  final List<PlaceSuggestion> suggestions;

  /// Whether a search is in progress.
  final bool searching;

  /// A copy with the given fields replaced; [clearAddress] removes the address.
  LocationPickerState copyWith({
    LocationAccess? access,
    LocationFix? me,
    GeoPoint? center,
    Place? address,
    List<PlaceSuggestion>? suggestions,
    bool? searching,
    bool clearAddress = false,
  }) {
    return LocationPickerState(
      access: access ?? this.access,
      me: me ?? this.me,
      center: center ?? this.center,
      address: clearAddress ? null : address ?? this.address,
      suggestions: suggestions ?? this.suggestions,
      searching: searching ?? this.searching,
    );
  }
}

/// The location picker pages' state.
final locationPickerProvider =
    NotifierProvider.autoDispose<LocationPicker, LocationPickerState>(
      LocationPicker.new,
    );

/// Drives the share and pick pages: permission, the phone's fix, the pin, its
/// address and the place search. Searches and address lookups are latest-wins.
class LocationPicker extends Notifier<LocationPickerState> {
  @override
  LocationPickerState build() => const LocationPickerState();

  int _searchSeq = 0;
  int _addressSeq = 0;

  /// Quietly fetches a fix when permission is already granted; never asks.
  Future<void> start() async {
    final granted = await ref.read(deviceLocationProvider).hasPermission();
    if (!ref.mounted || !granted) return;
    await _fix();
  }

  /// One tap: the phone's position with its address when known (else the
  /// coordinates). Asks for permission the first time.
  Future<Result<SharedLocation>> shareCurrent() async {
    final r = await ref.read(deviceLocationProvider).current();
    if (!ref.mounted) return const Err(LocationUnavailableFailure());
    switch (r) {
      case Err(:final failure):
        state = state.copyWith(access: _accessFor(failure, state.access));
        return Err(failure);
      case Ok(:final value):
        state = state.copyWith(access: LocationAccess.granted, me: value);
        final named = await ref.read(placeSearchProvider).reverse(value.point);
        if (!ref.mounted) return const Err(LocationUnavailableFailure());
        final place = named is Ok<Place?> ? named.value : null;
        return Ok(
          SharedLocation.clean(
            lat: value.point.lat,
            lng: value.point.lng,
            name: place?.name ?? '',
            address: place?.address ?? '',
          ),
        );
    }
  }

  Future<void> _fix() async {
    final r = await ref.read(deviceLocationProvider).current();
    if (!ref.mounted) return;
    switch (r) {
      case Err(:final failure):
        state = state.copyWith(access: _accessFor(failure, state.access));
      case Ok(:final value):
        state = state.copyWith(access: LocationAccess.granted, me: value);
    }
  }

  /// The pin now rests on [point]: forget the old address and look up the new.
  void moveTo(GeoPoint point) {
    final seq = ++_addressSeq;
    state = state.copyWith(center: point, clearAddress: true);
    unawaited(_lookup(point, seq));
  }

  /// Suggestions for [text] after a short pause; only the latest call counts.
  Future<void> search(String text) async {
    final q = text.trim();
    final seq = ++_searchSeq;
    if (q.isEmpty || !ref.read(placeSearchProvider).canSearch) {
      state = state.copyWith(suggestions: const [], searching: false);
      return;
    }
    state = state.copyWith(searching: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!ref.mounted || seq != _searchSeq) return;
    final r = await ref
        .read(placeSearchProvider)
        .suggest(q, near: state.center ?? state.me?.point);
    if (!ref.mounted || seq != _searchSeq) return;
    state = state.copyWith(
      searching: false,
      suggestions: r is Ok<List<PlaceSuggestion>> ? r.value : const [],
    );
  }

  /// The member picked a suggestion: the pin and address move to that place.
  Future<void> choose(PlaceSuggestion s) async {
    _searchSeq++;
    _addressSeq++;
    state = state.copyWith(suggestions: const [], searching: false);
    final r = await ref.read(placeSearchProvider).resolve(s);
    if (!ref.mounted) return;
    if (r is Ok<Place>) {
      state = state.copyWith(center: r.value.point, address: r.value);
    }
  }

  /// What the pin would send, or null when there is no pin yet.
  SharedLocation? pinned() {
    final c = state.center;
    if (c == null) return null;
    return SharedLocation.clean(
      lat: c.lat,
      lng: c.lng,
      name: state.address?.name ?? '',
      address: state.address?.address ?? '',
    );
  }

  LocationAccess _accessFor(Failure f, LocationAccess keep) => switch (f) {
    LocationDeniedFailure(:final forever) =>
      forever ? LocationAccess.deniedForever : LocationAccess.denied,
    LocationUnavailableFailure() => LocationAccess.unavailable,
    _ => keep,
  };

  Future<void> _lookup(GeoPoint point, int seq) async {
    final r = await ref.read(placeSearchProvider).reverse(point);
    if (!ref.mounted || seq != _addressSeq) return;
    final place = r is Ok<Place?> ? r.value : null;
    state = state.copyWith(address: place, clearAddress: place == null);
  }
}
