import 'package:flutter/material.dart';

import '../../services/haptic_service.dart';

/// Hero tag shared by the mini player's artwork and the full player's, so
/// the artwork flies between them when the player opens and closes.
const String kNowPlayingArtworkHeroTag = 'now-playing-artwork';

/// Full-screen player route that slides up from the bottom like a sheet and
/// can be dragged down to close, following the finger as iOS Music does.
class NowPlayingRoute<T> extends PageRoute<T> {
  NowPlayingRoute({required this.builder, super.settings})
      : super(fullscreenDialog: true);

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _DragToDismiss(route: this, child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      return FadeTransition(opacity: animation, child: child);
    }
    // While the user drags, follow the finger linearly; otherwise ease.
    final curved = navigator?.userGestureInProgress ?? false
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }

  /// Drives the route's own animation from a vertical drag.
  void _dragUpdate(double fraction) {
    controller!.value = (controller!.value - fraction).clamp(0.0, 1.0);
  }

  void _dragEnd(double velocityFraction) {
    final nav = navigator;
    final shouldClose =
        velocityFraction > 1.2 || (controller!.value < 0.7 && velocityFraction > -0.5);
    if (shouldClose) {
      HapticService.lightTap();
      nav?.pop();
    } else {
      controller!.forward();
    }
    nav?.didStopUserGesture();
  }
}

class _DragToDismiss extends StatefulWidget {
  const _DragToDismiss({required this.route, required this.child});

  final NowPlayingRoute<dynamic> route;
  final Widget child;

  @override
  State<_DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<_DragToDismiss> {
  bool _dragging = false;

  void _start(DragStartDetails _) {
    if (widget.route.isActive && !widget.route.navigator!.userGestureInProgress) {
      _dragging = true;
      widget.route.navigator!.didStartUserGesture();
    }
  }

  void _update(DragUpdateDetails d) {
    if (!_dragging) return;
    final height = context.size?.height ?? 800;
    widget.route._dragUpdate(d.primaryDelta! / height);
  }

  void _end(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final height = context.size?.height ?? 800;
    widget.route._dragEnd((d.primaryVelocity ?? 0) / height);
  }

  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    widget.route._dragEnd(0);
  }

  @override
  Widget build(BuildContext context) {
    // Scrollables inside (lyrics) win vertical drags in their own area.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _start,
      onVerticalDragUpdate: _update,
      onVerticalDragEnd: _end,
      onVerticalDragCancel: _cancel,
      child: widget.child,
    );
  }
}
