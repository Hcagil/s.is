import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../../core/failure.dart';
import '../domain/geo.dart';
import '../domain/location_services.dart';

/// [DeviceLocation] backed by the geolocator package; foreground only, never asks for background location.
final class GeolocatorDeviceLocation implements DeviceLocation {
  const GeolocatorDeviceLocation();

  @override
  Future<bool> hasPermission() async {
    try {
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.whileInUse ||
          p == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Result<LocationFix>> current() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.deniedForever) {
        return const Err(LocationDeniedFailure(forever: true));
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.unableToDetermine) {
        return const Err(LocationDeniedFailure());
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const Err(LocationUnavailableFailure());
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return Ok(
        LocationFix(GeoPoint(pos.latitude, pos.longitude), pos.accuracy),
      );
    } on PermissionDeniedException {
      return const Err(LocationDeniedFailure());
    } on LocationServiceDisabledException {
      return const Err(LocationUnavailableFailure());
    } on TimeoutException {
      return const Err(LocationUnavailableFailure());
    } catch (_) {
      return const Err(LocationUnavailableFailure());
    }
  }
}
