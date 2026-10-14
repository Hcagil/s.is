// The OSM location map keeps the member's zoom. Written from the contract
// only: after the member zooms out and the picker moves the target to the
// new centre (onCenterChanged), the camera stays at the member's zoom; a
// programmatic target change (the "my location" button) keeps the current
// zoom too, and never snaps back to the starting spec.zoom.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/osm_map_view.dart';
import 'package:sis/features/chat/domain/geo.dart';

const start = GeoPoint(41.0, 29.0);
const myLocation = GeoPoint(41.05, 29.05);

/// Mounts the map the way the picker does: the spec's target follows the
/// centre the map reports, and [goTo] stands in for "my location".
class _Picker extends StatefulWidget {
  const _Picker({super.key, this.follow = true});

  /// Whether the target follows the reported centre.
  final bool follow;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  GeoPoint target = start;
  int centreReports = 0;

  void goTo(GeoPoint p) => setState(() => target = p);

  @override
  Widget build(BuildContext context) => OsmMapView(
    MapViewSpec(
      target: target,
      onCenterChanged: (c) => setState(() {
        centreReports++;
        if (widget.follow) target = c;
      }),
    ),
  );
}

double zoom(WidgetTester t) =>
    t.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera.zoom;

LatLngLike centre(WidgetTester t) {
  final c = t
      .widget<FlutterMap>(find.byType(FlutterMap))
      .mapController!
      .camera
      .center;
  return (lat: c.latitude, lng: c.longitude);
}

typedef LatLngLike = ({double lat, double lng});

/// Two fingers pinch in: the member zooms out. Returns the zoom the
/// fingers left, read before the map settles.
Future<double> pinchOut(WidgetTester t) async {
  final mid = t.getCenter(find.byType(FlutterMap));
  final a = await t.startGesture(mid - const Offset(150, 0), pointer: 1);
  final b = await t.startGesture(mid + const Offset(150, 0), pointer: 2);
  for (var i = 0; i < 10; i++) {
    await a.moveBy(const Offset(12, 0));
    await b.moveBy(const Offset(-12, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  final left = zoom(t);
  await a.up();
  await b.up();
  await t.pumpAndSettle();
  return left;
}

Future<_PickerState> _mount(WidgetTester t, {bool follow = true}) async {
  final k = GlobalKey<_PickerState>();
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: _Picker(key: k, follow: follow),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return k.currentState!;
}

void main() {
  testWidgets('starts at the spec zoom', (t) async {
    await _mount(t);
    expect(zoom(t), 15);
  });

  testWidgets('a member zoom-out survives the centre update', (t) async {
    final picker = await _mount(t);
    final zoomed = await pinchOut(t);
    expect(zoomed, lessThan(14.5), reason: 'precondition: zoomed out');
    expect(picker.centreReports, greaterThan(0), reason: 'centre reported');

    expect(zoom(t), closeTo(zoomed, 1e-9));
  });

  testWidgets('"my location" keeps the current zoom', (t) async {
    // The target does not follow the centre here, so only the button moves it.
    final picker = await _mount(t, follow: false);
    final zoomed = await pinchOut(t);
    expect(zoomed, lessThan(14.5), reason: 'precondition: zoomed out');

    picker.goTo(myLocation);
    await t.pumpAndSettle();

    final c = centre(t);
    expect(c.lat, closeTo(myLocation.lat, 1e-6), reason: 'moved there');
    expect(c.lng, closeTo(myLocation.lng, 1e-6));
    expect(zoom(t), closeTo(zoomed, 1e-9));
  });
}
