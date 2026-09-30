import 'package:flutter/material.dart';

import '../../services/haptic_service.dart';

/// Base of the Hero tag shared by the mini player's artwork and the full
/// player's, so the artwork flies between them when the player opens and
/// closes. Use [nowPlayingArtworkHeroTag] for the actual tag.
const String kNowPlayingArtworkHeroTag = 'now-playing-artwork';

/// Hero tag of the mini player artwork on [route], and of the full player
/// opened from it. Scoped to the route: with one global tag, every push
/// between two pages that both show a mini player (library → album) flew
/// the artwork between their bars.
Object nowPlayingArtworkHeroTag(Route<dynamic>? route) =>
    (kNowPlayingArtworkHeroTag, route);

/// Full-screen player route that slides up from the bottom like a sheet and
/// can be dragged down to close, following the finger as iOS Music does.
class NowPlayingRoute<T> extends PageRoute<T> {
  NowPlayingRoute({required this.builder, this.opener, super.settings})
      : super(fullscreenDialog: true);

  final WidgetBuilder builder;

  /// The route whose mini player opened this player (see
  /// [artworkHeroTag]).
  final Route<dynamic>? opener;

  /// Hero tag for the player's artwork: matches the opener's mini player.
  Object get artworkHeroTag => nowPlayingArtworkHeroTag(opener);

  /// Player routes currently in a navigator (see [show]).
  static final Set<NowPlayingRoute<dynamic>> _installed = {};

  /// Opens the player built by [builder] from [context]. When a player is
  /// already open in that navigator (an album or artist page was pushed from
  /// it, and its mini player was tapped), returns to that player instead of
  /// stacking a second one.
  static void show(BuildContext context, WidgetBuilder builder) {
    final nav = Navigator.of(context);
    for (final route in _installed) {
      if (route.navigator == nav && route.isActive) {
        nav.popUntil((r) => identical(r, route));
        return;
      }
    }
    nav.push(NowPlayingRoute<void>(
      builder: builder,
      opener: ModalRoute.of(context),
    ));
  }

  // Created once: buildTransitions runs on every animation tick, and a
  // CurvedAnimation made per call would leave a status listener behind on
  // the route's controller each time.
  CurvedAnimation? _curved;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  // Opaque once open: the page below is then offstage (not laid out, painted
  // or rasterized, and its tickers muted) instead of being drawn in full,
  // blurs included, under the player on every frame. TransitionRoute makes
  // the route non-opaque while its animation runs, and a drag moves the
  // controller off `completed`, so the page below is still revealed while
  // opening, closing and dragging.
  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  void install() {
    super.install();
    _installed.add(this);
  }

  @override
  void dispose() {
    _installed.remove(this);
    _curved?.dispose();
    super.dispose();
  }

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
    // While the user drags, and while the release settles (the gesture only
    // ends once that animation finishes, see _dragEnd), follow the
    // controller linearly: it is already eased there. Switching to the
    // curve mid-flight would make the sheet jump.
    final Animation<double> position = navigator?.userGestureInProgress ?? false
        ? animation
        : (_curved ??= CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ));
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(position),
      child: child,
    );
  }

  /// Drives the route's own animation from a vertical drag.
  void _dragUpdate(double fraction) {
    controller!.value = (controller!.value - fraction).clamp(0.0, 1.0);
  }

  /// Settles the sheet after a drag, the way CupertinoPageRoute's back swipe
  /// does: the controller animates with an ease while the transition stays
  /// linear, and the user gesture ends only when that animation is done.
  void _dragEnd(double velocityFraction) {
    final nav = navigator;
    final ctrl = controller;
    if (nav == null || ctrl == null) return;
    final shouldClose =
        velocityFraction > 1.2 || (ctrl.value < 0.7 && velocityFraction > -0.5);
    if (shouldClose && isCurrent) {
      HapticService.lightTap();
      nav.pop();
      if (ctrl.isAnimating) {
        ctrl.animateBack(
          0.0,
          duration: reverseTransitionDuration * ctrl.value,
          curve: Curves.easeOutCubic,
        );
      }
    } else {
      ctrl.animateTo(
        1.0,
        duration: transitionDuration * (1.0 - ctrl.value),
        curve: Curves.easeOutCubic,
      );
    }
    if (ctrl.isAnimating) {
      late final AnimationStatusListener onStatus;
      onStatus = (AnimationStatus status) {
        nav.didStopUserGesture();
        ctrl.removeStatusListener(onStatus);
      };
      ctrl.addStatusListener(onStatus);
    } else {
      nav.didStopUserGesture();
    }
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
