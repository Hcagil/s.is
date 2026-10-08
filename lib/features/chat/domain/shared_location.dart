import 'shared_contact.dart';

/// A place travelling in a message. The message body is `name`, and when there is an address a line break and `address`, so an older build shows it as plain text. The coordinates travel in their own columns (see the send_location function).
final class SharedLocation {
  const SharedLocation({
    required this.lat,
    required this.lng,
    required this.name,
    this.address = '',
  });

  /// Cleans the text: runs of whitespace/control characters become one space, ends trimmed; name cut to locationMaxNameLength characters (runes), address to locationMaxAddressLength. An empty name becomes coordinatesText(lat, lng).
  factory SharedLocation.clean({
    required double lat,
    required double lng,
    String name = '',
    String address = '',
  }) {
    final cleanName = String.fromCharCodes(
      cleanContactText(name).runes.take(locationMaxNameLength),
    );
    final cleanAddress = String.fromCharCodes(
      cleanContactText(address).runes.take(locationMaxAddressLength),
    );
    return SharedLocation(
      lat: lat,
      lng: lng,
      name: cleanName.isEmpty ? coordinatesText(lat, lng) : cleanName,
      address: cleanAddress,
    );
  }

  final double lat;
  final double lng;
  final String name;
  final String address;

  /// name, or name + a line break + address when address is not empty.
  String get body => address.isEmpty ? name : '$name\n$address';

  /// True when the coordinates are valid, name is not empty and at most locationMaxNameLength runes, address at most locationMaxAddressLength runes, and name/address equal their cleaned form (no line break or control character inside them).
  bool get isSendable =>
      isValidCoordinate(lat, lng) &&
      name.isNotEmpty &&
      name.runes.length <= locationMaxNameLength &&
      address.runes.length <= locationMaxAddressLength &&
      name == cleanContactText(name) &&
      address == cleanContactText(address);

  /// Rebuilds a location from a stored row: null when lat or lng is null or not a valid coordinate or body is empty. The first line of body is the name, everything after the first line break is the address.
  static SharedLocation? fromRow({
    required double? lat,
    required double? lng,
    required String body,
  }) {
    if (lat == null ||
        lng == null ||
        !isValidCoordinate(lat, lng) ||
        body.isEmpty) {
      return null;
    }
    final i = body.indexOf('\n');
    if (i < 0) {
      return SharedLocation(lat: lat, lng: lng, name: body);
    }
    return SharedLocation(
      lat: lat,
      lng: lng,
      name: body.substring(0, i),
      address: body.substring(i + 1),
    );
  }
}

/// Latitude -90..90 and longitude -180..180, both finite.
bool isValidCoordinate(double lat, double lng) {
  return lat.isFinite &&
      lng.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180;
}

/// 'lat, lng' with 5 decimals each, e.g. '41.01234, 28.97834'.
String coordinatesText(double lat, double lng) {
  return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}

const int locationMaxNameLength = 80;
const int locationMaxAddressLength = 200;

/// The one-line chat-list preview of a location message (the app shows it in the app language, see conversation_tile).
const String locationPreviewText = '\u{1F4CD} Location';
