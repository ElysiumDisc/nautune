import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// A shimmer skeleton loader for placeholder content during loading
class SkeletonLoader extends StatefulWidget {
  const SkeletonLoader({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8.0,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

/// One shimmer phase shared by every [SkeletonLoader]: a loading grid has
/// dozens of them, and each used to run its own animation controller. The
/// clock ticks only while at least one loader is on screen and animating.
class _ShimmerClock extends ChangeNotifier {
  _ShimmerClock._();

  static final _ShimmerClock instance = _ShimmerClock._();

  static const Duration _period = Duration(milliseconds: 1500);

  final Set<Object> _clients = {};
  Ticker? _ticker;

  /// Position in the current cycle, 0-1.
  double phase = 0;

  void attach(Object client) {
    if (!_clients.add(client) || _clients.length > 1) return;
    _ticker ??= Ticker(_tick)..start();
  }

  void detach(Object client) {
    if (!_clients.remove(client) || _clients.isNotEmpty) return;
    _ticker?.dispose();
    _ticker = null;
  }

  void _tick(Duration elapsed) {
    phase = (elapsed.inMicroseconds % _period.inMicroseconds) /
        _period.inMicroseconds;
    notifyListeners();
  }
}

class _SkeletonLoaderState extends State<SkeletonLoader> {
  bool _animating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Still offstage (TickerMode off) and with Reduce Motion on.
    final animate = TickerMode.valuesOf(context).enabled &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (animate == _animating) return;
    _animating = animate;
    if (animate) {
      _ShimmerClock.instance.attach(this);
    } else {
      _ShimmerClock.instance.detach(this);
    }
  }

  @override
  void dispose() {
    _ShimmerClock.instance.detach(this);
    super.dispose();
  }

  /// Highlight position, as the old per-loader controller eased it: from
  /// -1 to 2 over the cycle, clamped to the box.
  double get _highlight {
    if (!_animating) return 0.5;
    final t = Curves.easeInOut.transform(_ShimmerClock.instance.phase);
    return (-1.0 + 3.0 * t).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.surfaceContainerHighest;
    final highlightColor = theme.colorScheme.surface;

    Widget box(BuildContext context, Widget? _) => Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                baseColor,
                highlightColor,
                baseColor,
              ],
              stops: [
                0.0,
                _highlight,
                1.0,
              ],
            ),
          ),
        );

    if (!_animating) return box(context, null);
    return ListenableBuilder(
      listenable: _ShimmerClock.instance,
      builder: box,
    );
  }
}

/// Skeleton loader for track chips in horizontal lists
class SkeletonTrackChip extends StatelessWidget {
  const SkeletonTrackChip({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonLoader(width: 160, height: 100, borderRadius: 12),
          SizedBox(height: 8),
          SkeletonLoader(width: 120, height: 14, borderRadius: 4),
          SizedBox(height: 4),
          SkeletonLoader(width: 80, height: 12, borderRadius: 4),
        ],
      ),
    );
  }
}

/// Skeleton loader for album cards in horizontal lists
class SkeletonAlbumCard extends StatelessWidget {
  const SkeletonAlbumCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonLoader(width: 150, height: 150, borderRadius: 12),
          SizedBox(height: 8),
          SkeletonLoader(width: 120, height: 14, borderRadius: 4),
          SizedBox(height: 4),
          SkeletonLoader(width: 90, height: 12, borderRadius: 4),
        ],
      ),
    );
  }
}

/// Horizontal list of skeleton track chips
class SkeletonTrackShelf extends StatelessWidget {
  const SkeletonTrackShelf({super.key, this.itemCount = 5});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: itemCount,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) => const SkeletonTrackChip(),
      ),
    );
  }
}

/// Horizontal list of skeleton album cards
class SkeletonAlbumShelf extends StatelessWidget {
  const SkeletonAlbumShelf({super.key, this.itemCount = 5});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: itemCount,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) => const SkeletonAlbumCard(),
      ),
    );
  }
}
