import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'directed_drag.dart';

/// A page dragged this fraction of its width (or more) leaves on release.
const double swipeBackLeaveFraction = 0.35;

/// Screen widths per second: a rightward flick at least this fast leaves, a
/// leftward one at least this fast stays.
const double swipeBackFlingVelocity = 1.0;

/// Route settings for a page whose own content pans or pages sideways (the
/// crop frame, the photo pager): the page-wide right drag is off there so it
/// cannot steal the content's drags; the back button and the system back
/// still leave.
const RouteSettings noSwipeBack = RouteSettings(name: 'no-swipe-back');

/// The iOS slide, wrapped so a right drag that starts ANYWHERE on the page
/// leaves it -- on Android and iPhone alike. The page follows the finger (the
/// route's own animation is driven by the drag), the keyboard closes when the
/// drag starts, and release past [swipeBackLeaveFraction] or a flick pops;
/// otherwise the page springs back.
class SwipeBackTransitionsBuilder extends PageTransitionsBuilder {
  const SwipeBackTransitionsBuilder();

  static const _slide = CupertinoPageTransitionsBuilder();

  // The iOS timing and the previous page's parallax come with the slide; the
  // base class would silently use 300 ms and no parallax.
  @override
  Duration get transitionDuration => _slide.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _slide.reverseTransitionDuration;

  // The page underneath stays put during a right-drag (no parallax), on both
  // platforms.
  @override
  DelegatedTransitionBuilder? get delegatedTransition => null;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _SwipeBack<T>(
      route: route,
      child: _slide.buildTransitions<T>(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

class _SwipeBack<T> extends StatefulWidget {
  const _SwipeBack({required this.route, required this.child});

  final PageRoute<T> route;
  final Widget child;

  @override
  State<_SwipeBack<T>> createState() => _SwipeBackState<T>();
}

class _SwipeBackState<T> extends State<_SwipeBack<T>> {
  late final DirectedDragRecognizer _recognizer =
      DirectedDragRecognizer(direction: 1, debugOwner: this)
        ..onStart = _start
        ..onUpdate = _update
        ..onEnd = _end
        ..onCancel = _cancel;

  double _fraction = 0;
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      child: widget.child,
    );
  }

  void _down(PointerDownEvent e) {
    final route = widget.route;
    if (route.isCurrent &&
        route.popGestureEnabled &&
        route.settings.name != noSwipeBack.name) {
      _recognizer.addPointer(e);
    }
  }

  void _start(DragStartDetails _) {
    FocusManager.instance.primaryFocus?.unfocus();
    _fraction = 0;
    _active = true;
    widget.route.handleStartBackGesture(progress: 1.0);
  }

  void _update(DragUpdateDetails d) {
    _fraction += d.primaryDelta! / context.size!.width;
    widget.route.handleUpdateBackGestureProgress(
      progress: (1 - _fraction).clamp(0.0, 1.0),
    );
  }

  void _end(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx / context.size!.width;
    _finish(
      v >= swipeBackFlingVelocity ||
          (v > -swipeBackFlingVelocity && _fraction >= swipeBackLeaveFraction),
    );
  }

  void _cancel() {
    if (_active) _finish(false);
  }

  void _finish(bool leave) {
    _active = false;
    final route = widget.route;
    if (!leave) {
      route.handleCancelBackGesture();
      return;
    }
    // Not handleCommitBackGesture: it restarts the slide-out from fully open.
    final nav = route.navigator!;
    nav.pop();
    // The gesture flag stays up until the slide-out ends, so the transition
    // curve does not change mid-flight.
    final a = route.animation!;
    if (a.isDismissed) {
      nav.didStopUserGesture();
      return;
    }
    late AnimationStatusListener l;
    l = (s) {
      if (s == AnimationStatus.dismissed) {
        a.removeStatusListener(l);
        if (nav.mounted) nav.didStopUserGesture();
      }
    };
    a.addStatusListener(l);
  }

  @override
  void dispose() {
    _recognizer.dispose();
    final nav = widget.route.navigator;
    if (_active && nav != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (nav.mounted) nav.didStopUserGesture();
      });
    }
    super.dispose();
  }
}
