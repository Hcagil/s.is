import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/shared_location.dart';

void main() {
  group('SharedLocation', () {
    test('body with and without address', () {
      const locWithAddr = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(locWithAddr.body, equals('Place\n123 St'));

      const locNoAddr = SharedLocation(lat: 10, lng: 20, name: 'Place');
      expect(locNoAddr.body, equals('Place'));
    });

    test('clean collapses whitespace and control chars', () {
      final cleaned = SharedLocation.clean(
        lat: 10,
        lng: 20,
        name: '  Kadıköy \n\t İskele  ',
        address: '  123 \n\t Street  ',
      );
      expect(cleaned.name, equals('Kadıköy İskele'));
      expect(cleaned.address, equals('123 Street'));
    });

    test('clean truncates name and address to max lengths', () {
      final longName = 'a' * 100;
      final longAddr = 'b' * 250;
      final cleaned = SharedLocation.clean(
        lat: 0,
        lng: 0,
        name: longName,
        address: longAddr,
      );
      expect(cleaned.name.runes.length, equals(locationMaxNameLength));
      expect(cleaned.address.runes.length, equals(locationMaxAddressLength));
    });

    test('clean truncates to exact max lengths', () {
      final name81 = 'a' * 81;
      final name80 = 'a' * 80;
      final addr201 = 'b' * 201;
      final addr200 = 'b' * 200;

      final cleaned81 = SharedLocation.clean(lat: 0, lng: 0, name: name81);
      expect(cleaned81.name.runes.length, equals(locationMaxNameLength));

      final cleaned80 = SharedLocation.clean(lat: 0, lng: 0, name: name80);
      expect(cleaned80.name.runes.length, equals(locationMaxNameLength));

      final cleanedAddr201 = SharedLocation.clean(
        lat: 0,
        lng: 0,
        address: addr201,
      );
      expect(
        cleanedAddr201.address.runes.length,
        equals(locationMaxAddressLength),
      );

      final cleanedAddr200 = SharedLocation.clean(
        lat: 0,
        lng: 0,
        address: addr200,
      );
      expect(
        cleanedAddr200.address.runes.length,
        equals(locationMaxAddressLength),
      );
    });

    test('clean with empty or whitespace-only name uses coordinatesText', () {
      final cleaned = SharedLocation.clean(
        lat: 12.345,
        lng: 67.890,
        name: '   ',
      );
      expect(cleaned.name, equals(coordinatesText(12.345, 67.890)));
    });

    test('body property', () {
      final loc = SharedLocation(lat: 0, lng: 0, name: 'Name', address: '');
      expect(loc.body, equals('Name'));

      final loc2 = SharedLocation(
        lat: 0,
        lng: 0,
        name: 'Name',
        address: 'Addr',
      );
      expect(loc2.body, equals('Name\nAddr'));
    });

    test('isSendable true for clean value', () {
      final cleanLoc = SharedLocation.clean(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(cleanLoc.isSendable, isTrue);
    });

    test('isSendable false for each fault alone', () {
      final base = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(base.isSendable, isTrue);

      final invalidLatHigh = SharedLocation(
        lat: 90.0001,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(invalidLatHigh.isSendable, isFalse);

      final invalidLatLow = SharedLocation(
        lat: -90.0001,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(invalidLatLow.isSendable, isFalse);

      final invalidLngHigh = SharedLocation(
        lat: 10,
        lng: 180.0001,
        name: 'Place',
        address: '123 St',
      );
      expect(invalidLngHigh.isSendable, isFalse);

      final invalidLngLow = SharedLocation(
        lat: 10,
        lng: -180.0001,
        name: 'Place',
        address: '123 St',
      );
      expect(invalidLngLow.isSendable, isFalse);

      final latNaN = SharedLocation(
        lat: double.nan,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(latNaN.isSendable, isFalse);

      final lngInf = SharedLocation(
        lat: 10,
        lng: double.infinity,
        name: 'Place',
        address: '123 St',
      );
      expect(lngInf.isSendable, isFalse);

      final emptyName = SharedLocation(
        lat: 10,
        lng: 20,
        name: '',
        address: '123 St',
      );
      expect(emptyName.isSendable, isFalse);

      final overName = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'a' * 81,
        address: '123 St',
      );
      expect(overName.isSendable, isFalse);

      final overAddr = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: 'b' * 201,
      );
      expect(overAddr.isSendable, isFalse);

      final nameWithNewline = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place\nName',
        address: '123 St',
      );
      expect(nameWithNewline.isSendable, isFalse);

      final addrWithTab = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: '123\tSt',
      );
      expect(addrWithTab.isSendable, isFalse);

      final nameLeadingSpace = SharedLocation(
        lat: 10,
        lng: 20,
        name: ' Place',
        address: '123 St',
      );
      expect(nameLeadingSpace.isSendable, isFalse);
    });

    test('isSendable true at coordinate and length edges', () {
      final edgeLat90 = SharedLocation(
        lat: 90,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(edgeLat90.isSendable, isTrue);

      final edgeLatNeg90 = SharedLocation(
        lat: -90,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      expect(edgeLatNeg90.isSendable, isTrue);

      final edgeLng180 = SharedLocation(
        lat: 10,
        lng: 180,
        name: 'Place',
        address: '123 St',
      );
      expect(edgeLng180.isSendable, isTrue);

      final edgeLngNeg180 = SharedLocation(
        lat: 10,
        lng: -180,
        name: 'Place',
        address: '123 St',
      );
      expect(edgeLngNeg180.isSendable, isTrue);

      final edgeName80 = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'a' * 80,
        address: '123 St',
      );
      expect(edgeName80.isSendable, isTrue);

      final edgeAddr200 = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: 'b' * 200,
      );
      expect(edgeAddr200.isSendable, isTrue);
    });

    test('fromRow round trip', () {
      final original = SharedLocation(
        lat: 10,
        lng: 20,
        name: 'Place',
        address: '123 St',
      );
      final body = original.body;
      final parsed = SharedLocation.fromRow(
        lat: original.lat,
        lng: original.lng,
        body: body,
      );
      expect(parsed, isNotNull);
      expect(parsed!.lat, equals(original.lat));
      expect(parsed.lng, equals(original.lng));
      expect(parsed.name, equals(original.name));
      expect(parsed.address, equals(original.address));
    });

    test('fromRow with two line breaks', () {
      final body = 'A\nB\nC';
      final parsed = SharedLocation.fromRow(lat: 0, lng: 0, body: body);
      expect(parsed, isNotNull);
      expect(parsed!.name, equals('A'));
      expect(parsed.address, equals('B\nC'));
    });

    test('fromRow null lat/lng', () {
      expect(SharedLocation.fromRow(lat: null, lng: 0, body: 'A'), isNull);
      expect(SharedLocation.fromRow(lat: 0, lng: null, body: 'A'), isNull);
    });

    test('fromRow invalid coordinates or empty body', () {
      expect(SharedLocation.fromRow(lat: 91, lng: 0, body: 'A'), isNull);
      expect(SharedLocation.fromRow(lat: 0, lng: 0, body: ''), isNull);
    });

    test('coordinatesText examples', () {
      expect(
        coordinatesText(41.012344, 28.978339),
        equals('41.01234, 28.97834'),
      );
      expect(
        coordinatesText(-33.8688, 151.2093),
        equals('-33.86880, 151.20930'),
      );
    });

    test('isValidCoordinate edges', () {
      expect(isValidCoordinate(90, 0), isTrue);
      expect(isValidCoordinate(-90, 0), isTrue);
      expect(isValidCoordinate(0, 180), isTrue);
      expect(isValidCoordinate(0, -180), isTrue);
      expect(isValidCoordinate(90.0001, 0), isFalse);
      expect(isValidCoordinate(-90.0001, 0), isFalse);
      expect(isValidCoordinate(0, 180.0001), isFalse);
      expect(isValidCoordinate(0, -180.0001), isFalse);
      expect(isValidCoordinate(double.nan, 0), isFalse);
      expect(isValidCoordinate(0, double.infinity), isFalse);
    });

    test('constants values', () {
      expect(locationMaxNameLength, equals(80));
      expect(locationMaxAddressLength, equals(200));
      expect(locationPreviewText, equals('\u{1F4CD} Location'));
    });
  });
}
