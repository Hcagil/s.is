import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../domain/geo.dart';

/// A map view using OpenStreetMap tiles.
Widget osmMapView(MapViewSpec spec) => OsmMapView(spec);

/// A small map that cannot be moved, for a chat bubble.
Widget osmMapPreview(GeoPoint point) => IgnorePointer(
  child: OsmMapView(MapViewSpec(target: point, interactive: false)),
);

/// A map view using OpenStreetMap tiles.
class OsmMapView extends StatefulWidget {
  /// Creates a new [OsmMapView] with the given [spec].
  const OsmMapView(this.spec, {super.key});

  /// The specification of the map view.
  final MapViewSpec spec;

  @override
  State<OsmMapView> createState() => _OsmMapViewState();
}

class _OsmMapViewState extends State<OsmMapView> {
  final MapController _controller = MapController();

  @override
  Widget build(BuildContext context) {
    final t = widget.spec.target;
    final me = widget.spec.me;
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: LatLng(t.lat, t.lng),
        initialZoom: widget.spec.zoom,
        interactionOptions: InteractionOptions(
          flags: widget.spec.interactive
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.none,
        ),
        onMapEvent: _onEvent,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.esd.sis',
        ),
        if (me != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(me.lat, me.lng),
                width: 18,
                height: 18,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A73E8),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFFFFFFF),
                      width: 3,
                    ),
                  ),
                ),
              ),
            ],
          ),
        const RichAttributionWidget(
          attributions: [TextSourceAttribution('OpenStreetMap contributors')],
        ),
      ],
    );
  }

  @override
  void didUpdateWidget(OsmMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.spec.target;
    if (target != oldWidget.spec.target) {
      _controller.move(LatLng(target.lat, target.lng), widget.spec.zoom);
    }
  }

  void _onEvent(MapEvent e) {
    // The app's own moves (MapController) are not the member's.
    if (e.source == MapEventSource.mapController) return;
    if (e is MapEventMoveStart) {
      widget.spec.onMoveStart?.call();
    } else if (e is MapEventMoveEnd) {
      widget.spec.onCenterChanged?.call(
        GeoPoint(e.camera.center.latitude, e.camera.center.longitude),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
