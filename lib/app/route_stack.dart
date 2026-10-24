import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The one RouteStack the app's Navigator reports to (SisApp registers it).
final routeStackProvider = Provider<RouteStack>((_) => RouteStack());

/// Route settings for the full-screen photo and video viewers: the top
/// message card stays hidden while one of them is on top.
const RouteSettings fullScreenMedia = RouteSettings(name: 'full-screen-media');

/// Tracks the pushed routes so the session gate can remove every page above
/// the first at once, without a transition.
class RouteStack extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];

  /// True while the top route is a full-screen viewer ([fullScreenMedia]).
  final mediaOnTop = ValueNotifier<bool>(false);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (i >= 0) {
      _routes[i] = newRoute;
    } else {
      _routes.add(newRoute);
    }
    _update();
  }

  void _update() => mediaOnTop.value =
      _routes.isNotEmpty && _routes.last.settings.name == fullScreenMedia.name;

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
