import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The one RouteStack the app's Navigator reports to (SisApp registers it).
final routeStackProvider = Provider<RouteStack>((_) => RouteStack());

/// Tracks the pushed routes so the session gate can remove every page above
/// the first at once, without a transition.
class RouteStack extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (i >= 0) {
      _routes[i] = newRoute;
    } else {
      _routes.add(newRoute);
    }
  }

  /// Removes every route above the first with no transition, in this frame.
  /// Does nothing when there is nothing to remove.
  void removeAllAboveFirst() {
    final nav = navigator;
    if (nav == null) return;
    for (final r in List.of(_routes.reversed)) {
      if (!r.isFirst) nav.removeRoute(r);
    }
  }
}
