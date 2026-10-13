import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/geo.dart';

/// Builds a map the member can move. The real one (Google or OpenStreetMap)
/// is set in main.dart, because only the data layer may use a map SDK.
final mapViewProvider = Provider<Widget Function(MapViewSpec)>(
  (_) => throw UnimplementedError('override in main'),
);

/// Builds the small map picture inside a location bubble. Set in main.dart.
final mapPreviewProvider = Provider<Widget Function(GeoPoint)>(
  (_) => throw UnimplementedError('override in main'),
);
