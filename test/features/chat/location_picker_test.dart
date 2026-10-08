import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/geo.dart';
import 'package:sis/features/chat/domain/shared_location.dart';

import '../../support/location_fakes.dart';

Future<void> until(bool Function() ok, String what) async {
  for (var i = 0; i < 200; i++) {
    if (ok()) return;
    await Future.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out: $what');
}

void main() {
  group('LocationPicker', () {
    test('start() never asks for permission', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      await picker.start();
      expect(device.currentCalls, 0);
      expect(device.hasPermissionCalls, greaterThan(0));
      expect(
        c.read(locationPickerProvider).access,
        isNot(LocationAccess.granted),
      );
    });

    test('start() with permission already granted shows me', () async {
      final device = FakeDeviceLocation(granted: true);
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      await picker.start();
      await until(
        () => c.read(locationPickerProvider).me != null,
        'me not set',
      );
      final state = c.read(locationPickerProvider);
      expect(state.access, LocationAccess.granted);
      expect(state.me!.point, const GeoPoint(41.0, 29.0));
    });

    test('shareCurrent denied', () async {
      final device = FakeDeviceLocation();
      device.answer = const Err(LocationDeniedFailure());
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      final r = await picker.shareCurrent();
      expect(r, isA<Err<SharedLocation>>());
      final err = r as Err<SharedLocation>;
      expect(err.failure, isA<LocationDeniedFailure>());
      expect((err.failure as LocationDeniedFailure).forever, isFalse);
      expect(c.read(locationPickerProvider).access, LocationAccess.denied);
    });

    test('shareCurrent denied forever', () async {
      final device = FakeDeviceLocation();
      device.answer = const Err(LocationDeniedFailure(forever: true));
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      final r = await picker.shareCurrent();
      expect(r, isA<Err<SharedLocation>>());
      final err = r as Err<SharedLocation>;
      expect(err.failure, isA<LocationDeniedFailure>());
      expect((err.failure as LocationDeniedFailure).forever, isTrue);
      expect(
        c.read(locationPickerProvider).access,
        LocationAccess.deniedForever,
      );
    });

    test('shareCurrent unavailable', () async {
      final device = FakeDeviceLocation();
      device.answer = const Err(LocationUnavailableFailure());
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      final r = await picker.shareCurrent();
      expect(r, isA<Err<SharedLocation>>());
      final err = r as Err<SharedLocation>;
      expect(err.failure, isA<LocationUnavailableFailure>());
      expect(c.read(locationPickerProvider).access, LocationAccess.unavailable);
    });

    test('shareCurrent ok', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      final r = await picker.shareCurrent();
      expect(r, isA<Ok<SharedLocation>>());
      final ok = r as Ok<SharedLocation>;
      expect(ok.value.lat, 41.0);
      expect(ok.value.lng, 29.0);
      expect(ok.value.isSendable, isTrue);
      expect(device.currentCalls, 1);
      expect(c.read(locationPickerProvider).access, LocationAccess.granted);
    });

    test('shareCurrent waits for a slow fix', () async {
      final device = FakeDeviceLocation();
      device.gate = Completer<void>();
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      var done = false;
      final f = picker.shareCurrent().then((r) {
        done = true;
        return r;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse);
      device.gate!.complete();
      final r = await f;
      expect(r, isA<Ok<SharedLocation>>());
    });

    test('search is debounced', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      unawaited(picker.search('i'));
      unawaited(picker.search('is'));
      unawaited(picker.search('ist'));
      await Future.delayed(const Duration(milliseconds: 200));
      expect(search.queries, isEmpty);
      await Future.delayed(const Duration(milliseconds: 250));
      expect(search.queries, ['ist']);
    });

    test('search shows the results', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      search.results['moda'] = [
        PlaceSuggestion(
          id: 'p1',
          name: 'Moda Cd. 12',
          address: 'Kadikoy, Istanbul',
        ),
      ];
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      unawaited(picker.search('moda'));
      await until(
        () => c.read(locationPickerProvider).suggestions.isNotEmpty,
        'suggestions not set',
      );
      final state = c.read(locationPickerProvider);
      expect(state.suggestions.single.id, 'p1');
    });

    test('the latest search wins', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      search.hold = true;
      search.results['ank'] = [PlaceSuggestion(id: 'a', name: 'Ankara')];
      search.results['ist'] = [PlaceSuggestion(id: 'i', name: 'Istanbul')];
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      unawaited(picker.search('ank'));
      await until(() => search.queries.length == 1, 'first query not queued');
      unawaited(picker.search('ist'));
      await until(() => search.queries.length == 2, 'second query not queued');
      search.reply('ist');
      await until(
        () => c.read(locationPickerProvider).suggestions.isNotEmpty,
        'first result not set',
      );
      search.reply('ank');
      await Future.delayed(const Duration(milliseconds: 100));
      expect(c.read(locationPickerProvider).suggestions.map((s) => s.id), [
        'i',
      ]);
    });

    test('choose moves the pin to the place', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      final s = PlaceSuggestion(
        id: 'p1',
        name: 'Moda Cd. 12',
        address: 'Kadikoy, Istanbul',
      );
      search.places['p1'] = Place(
        point: const GeoPoint(40.987, 29.027),
        name: 'Moda Cd. 12',
        address: 'Kadikoy, Istanbul',
      );
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      await picker.choose(s);
      expect(search.resolved, [s]);
      final state = c.read(locationPickerProvider);
      expect(state.center, const GeoPoint(40.987, 29.027));
      final p = picker.pinned()!;
      expect(p.lat, 40.987);
      expect(p.lng, 29.027);
      expect(p.name, 'Moda Cd. 12');
      expect(p.address, 'Kadikoy, Istanbul');
    });

    test('moveTo looks the address up', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      picker.moveTo(const GeoPoint(40.99, 29.03));
      await until(
        () => c.read(locationPickerProvider).address != null,
        'address not set',
      );
      final state = c.read(locationPickerProvider);
      expect(search.reversed.last, const GeoPoint(40.99, 29.03));
      expect(state.center, const GeoPoint(40.99, 29.03));
      final p = picker.pinned()!;
      expect(p.name, 'Pin street 1');
      expect(p.address, 'Kadikoy, Istanbul');
      expect(p.lat, 40.99);
    });

    test('the last move wins', () async {
      final device = FakeDeviceLocation();
      final search = FakePlaceSearch();
      final c = ProviderContainer.test(
        overrides: locationOverrides(device: device, search: search),
      );
      c.listen(locationPickerProvider, (_, _) {});
      final picker = c.read(locationPickerProvider.notifier);
      picker.moveTo(const GeoPoint(1, 1));
      picker.moveTo(const GeoPoint(2, 2));
      await until(() {
        final state = c.read(locationPickerProvider);
        return state.address != null &&
            state.address!.point == const GeoPoint(2, 2);
      }, 'last address not set');
      await Future.delayed(const Duration(milliseconds: 100));
      final state = c.read(locationPickerProvider);
      expect(state.center, const GeoPoint(2, 2));
      expect(picker.pinned()!.lat, 2);
    });
  });
}
