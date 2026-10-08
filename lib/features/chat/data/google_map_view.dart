import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../domain/geo.dart';

/// Creates a Google Map widget from the given map view specification.
Widget googleMapView(MapViewSpec spec) => GoogleMapView(spec);

/// A Flutter widget that wraps the google_maps_flutter GoogleMap.
class GoogleMapView extends StatefulWidget {
  /// Creates a new GoogleMapView with the given specification.
  const GoogleMapView(this.spec, {super.key});

  /// The map view specification.
  final MapViewSpec spec;

  @override
  State<GoogleMapView> createState() => _GoogleMapViewState();
}

class _GoogleMapViewState extends State<GoogleMapView> {
  GoogleMapController? _controller;
  late GeoPoint _center = widget.spec.target;
  GeoPoint? _programTarget;
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    final me = widget.spec.me;
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(_center.lat, _center.lng),
        zoom: widget.spec.zoom,
      ),
      onMapCreated: (c) => _controller = c,
      onCameraMoveStarted: _onMoveStarted,
      onCameraMove: (p) =>
          _center = GeoPoint(p.target.latitude, p.target.longitude),
      onCameraIdle: _onIdle,
      markers: {
        if (me != null)
          Marker(
            markerId: const MarkerId('me'),
            position: LatLng(me.lat, me.lng),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
            anchor: const Offset(0.5, 0.5),
          ),
      },
      zoomControlsEnabled: false,
      myLocationButtonEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      scrollGesturesEnabled: widget.spec.interactive,
      zoomGesturesEnabled: widget.spec.interactive,
    );
  }

  @override
  void didUpdateWidget(GoogleMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.spec.target;
    final controller = _controller;
    // The member's own drag ends with the page telling us the new centre; the
    // camera is already there, so there is nothing to animate (and no idle).
    final here =
        (target.lat - _center.lat).abs() < 1e-5 &&
        (target.lng - _center.lng).abs() < 1e-5;
    if (target != oldWidget.spec.target && controller != null && !here) {
      _programTarget = target;
      unawaited(
        controller.animateCamera(
          CameraUpdate.newLatLng(LatLng(target.lat, target.lng)),
        ),
      );
    }
  }

  void _onMoveStarted() {
    if (_programTarget != null) return;
    _moved = true;
    widget.spec.onMoveStart?.call();
  }

  void _onIdle() {
    if (_programTarget != null) {
      _programTarget = null;
      _moved = false;
      return;
    }
    if (!_moved) return;
    _moved = false;
    widget.spec.onCenterChanged?.call(_center);
  }
}
