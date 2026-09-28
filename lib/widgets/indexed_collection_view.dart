import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../theme/nautune_spacing.dart';
import '../theme/nautune_theme.dart';
import '../utils/letter_index.dart';

/// A library collection (albums, artists, genres) as a list or a grid, with
/// sticky letter headers and an iOS-style A-Z index strip when [indexed].
///
/// Every row has a fixed extent and the section geometry is computed with
/// the same numbers the slivers use, so the index strip jumps exactly to a
/// letter, and scrolling never lays out more than what's on screen.
class IndexedCollectionView<T> extends StatefulWidget {
  const IndexedCollectionView({
    super.key,
    required this.items,
    required this.nameOf,
    required this.controller,
    required this.listItemBuilder,
    required this.gridItemBuilder,
    this.listMode = false,
    this.columns = 2,
    this.indexed = true,
    this.ascending = true,
    this.listItemExtent = 72,
    this.gridItemExtent = _squareArtWithCaption,
    this.gridSpacing = NautuneSpacing.lg,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.onLoadAll,
    this.onRefresh,
  });

  final List<T> items;

  /// Name used for grouping (should match the server's sort name).
  final String Function(T item) nameOf;
  final ScrollController controller;
  final Widget Function(BuildContext context, T item) listItemBuilder;
  final Widget Function(BuildContext context, T item) gridItemBuilder;
  final bool listMode;
  final int columns;

  /// Letter sections and index strip; only meaningful when sorted by name.
  final bool indexed;
  final bool ascending;
  final double listItemExtent;

  /// Height of a grid cell for a given cell width.
  final double Function(double tileWidth) gridItemExtent;
  final double gridSpacing;
  final bool isLoadingMore;

  /// More pages exist on the server.
  final bool hasMore;

  /// Loads every remaining page; used when the index jumps past what's
  /// loaded.
  final Future<void> Function()? onLoadAll;
  final Future<void> Function()? onRefresh;

  static double _squareArtWithCaption(double tileWidth) => tileWidth + 52;

  @override
  State<IndexedCollectionView<T>> createState() =>
      _IndexedCollectionViewState<T>();
}

class _IndexedCollectionViewState<T> extends State<IndexedCollectionView<T>> {
  static const double _headerExtent = 32;
  static const double _leading = NautuneSpacing.sm;
  static const double _stripWidth = 22;

  List<LetterSection<T>>? _sections;
  List<T>? _sectionsItems;
  bool? _sectionsAscending;
  bool _loadingAll = false;

  List<LetterSection<T>> get _currentSections {
    if (!identical(_sectionsItems, widget.items) ||
        _sectionsAscending != widget.ascending ||
        _sections == null) {
      _sectionsItems = widget.items;
      _sectionsAscending = widget.ascending;
      _sections = sectionsByLetter(
        widget.items,
        widget.nameOf,
        ascending: widget.ascending,
      );
    }
    return _sections!;
  }

  double _gutter(bool indexed) =>
      indexed ? _stripWidth + NautuneSpacing.xs : NautuneSpacing.lg;

  ({double tileWidth, double itemExtent}) _gridMetrics(
      double width, bool indexed) {
    final cols = widget.columns.clamp(1, 12);
    final usable = width - NautuneSpacing.lg - _gutter(indexed) -
        (cols - 1) * widget.gridSpacing;
    final tileWidth = (usable / cols).clamp(40.0, double.infinity);
    return (tileWidth: tileWidth, itemExtent: widget.gridItemExtent(tileWidth));
  }

  SectionGeometry _geometry(double width, bool indexed) {
    if (widget.listMode) {
      return SectionGeometry(
        headerExtent: indexed ? _headerExtent : 0,
        itemExtent: widget.listItemExtent,
      );
    }
    return SectionGeometry(
      headerExtent: indexed ? _headerExtent : 0,
      itemExtent: _gridMetrics(width, indexed).itemExtent,
      columns: widget.columns.clamp(1, 12),
      rowSpacing: widget.gridSpacing,
      paddingTop: NautuneSpacing.xs,
      paddingBottom: NautuneSpacing.md,
    );
  }

  Future<void> _jumpToLetter(String letter, double width) async {
    final controller = widget.controller;
    var sections = _currentSections;
    var present = [for (final s in sections) s.letter];

    if (widget.hasMore &&
        widget.onLoadAll != null &&
        !_loadingAll &&
        letterBeyondLoaded(letter, present, ascending: widget.ascending)) {
      setState(() => _loadingAll = true);
      try {
        await widget.onLoadAll!();
      } finally {
        if (mounted) setState(() => _loadingAll = false);
      }
      if (!mounted) return;
      // Let the list rebuild with the new items before measuring.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      sections = _currentSections;
      present = [for (final s in sections) s.letter];
    }

    final resolved =
        resolveIndexLetter(letter, present, ascending: widget.ascending);
    if (resolved == null || !controller.hasClients) return;
    final offsets =
        sectionOffsets(sections, _geometry(width, true), leading: _leading);
    final position = controller.position;
    final target = offsets[resolved]!
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final indexed = widget.indexed && widget.items.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final sections = indexed
            ? _currentSections
            : [LetterSection<T>('', widget.items)];
        final slivers = <Widget>[
          if (widget.onRefresh != null)
            CupertinoSliverRefreshControl(onRefresh: widget.onRefresh),
          const SliverToBoxAdapter(child: SizedBox(height: _leading)),
          for (final section in sections)
            indexed
                ? SliverMainAxisGroup(
                    slivers: [
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _LetterHeaderDelegate(
                          section.letter,
                          _headerExtent,
                        ),
                      ),
                      _body(context, section.items, width, indexed),
                    ],
                  )
                : _body(context, section.items, width, indexed),
          if (widget.isLoadingMore || _loadingAll)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(NautuneSpacing.lg),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            ),
          const SliverToBoxAdapter(
            child: SizedBox(height: NautuneSpacing.xxl),
          ),
        ];

        final scrollView = CustomScrollView(
          controller: widget.controller,
          scrollCacheExtent: ScrollCacheExtent.pixels(800),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: slivers,
        );

        if (!indexed) return scrollView;
        return Stack(
          children: [
            scrollView,
            Positioned(
              right: 0,
              top: _headerExtent,
              bottom: NautuneSpacing.lg,
              width: _stripWidth + NautuneSpacing.xs,
              child: _IndexStrip(
                letters: widget.ascending
                    ? kIndexLetters
                    : kIndexLetters.reversed.toList(),
                present: {for (final s in sections) s.letter},
                loading: _loadingAll,
                onLetter: (letter) => _jumpToLetter(letter, width),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _body(
      BuildContext context, List<T> items, double width, bool indexed) {
    if (widget.listMode) {
      return SliverPadding(
        padding: EdgeInsets.only(right: indexed ? _stripWidth : 0),
        sliver: SliverFixedExtentList(
          itemExtent: widget.listItemExtent,
          delegate: SliverChildBuilderDelegate(
            (context, i) => widget.listItemBuilder(context, items[i]),
            childCount: items.length,
            addAutomaticKeepAlives: false,
          ),
        ),
      );
    }
    final metrics = _gridMetrics(width, indexed);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        NautuneSpacing.lg,
        indexed ? NautuneSpacing.xs : 0,
        _gutter(indexed),
        indexed ? NautuneSpacing.md : 0,
      ),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: widget.columns.clamp(1, 12),
          mainAxisExtent: metrics.itemExtent,
          crossAxisSpacing: widget.gridSpacing,
          mainAxisSpacing: widget.gridSpacing,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => widget.gridItemBuilder(context, items[i]),
          childCount: items.length,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }
}

/// Sticky letter header, frosted like an iOS table section header.
class _LetterHeaderDelegate extends SliverPersistentHeaderDelegate {
  _LetterHeaderDelegate(this.letter, this.extent);

  final String letter;
  final double extent;

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final theme = Theme.of(context);
    final style = NautuneStyle.of(context);
    return Semantics(
      header: true,
      child: Container(
        color: style.groupedBackground.withValues(
          alpha: shrinkOffset > 0 || overlapsContent ? 0.94 : 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: NautuneSpacing.lg),
        alignment: Alignment.centerLeft,
        child: Text(
          letter,
          style: theme.textTheme.headline.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_LetterHeaderDelegate old) =>
      old.letter != letter || old.extent != extent;
}

/// The A-Z strip along the right edge. Tap or drag; a haptic tick marks
/// each new letter, and a bubble shows the letter under the finger.
class _IndexStrip extends StatefulWidget {
  const _IndexStrip({
    required this.letters,
    required this.present,
    required this.loading,
    required this.onLetter,
  });

  final List<String> letters;
  final Set<String> present;
  final bool loading;
  final ValueChanged<String> onLetter;

  @override
  State<_IndexStrip> createState() => _IndexStripState();
}

class _IndexStripState extends State<_IndexStrip> {
  String? _active;
  double _activeY = 0;

  List<String> _visibleLetters(double height) {
    const minLetterHeight = 13.0;
    final fit = (height / minLetterHeight).floor();
    if (fit >= widget.letters.length || fit <= 1) return widget.letters;
    // Too short for every letter: show every n-th, like iOS does with dots.
    final step = (widget.letters.length / fit).ceil();
    return [
      for (var i = 0; i < widget.letters.length; i += step) widget.letters[i],
    ];
  }

  void _handle(double dy, double height) {
    // Map the finger to the full alphabet even when letters are elided.
    final all = widget.letters;
    final index = (dy / height * all.length).floor().clamp(0, all.length - 1);
    final letter = all[index];
    if (letter == _active) return;
    setState(() {
      _active = letter;
      _activeY = dy.clamp(0, height);
    });
    HapticFeedback.selectionClick();
    widget.onLetter(letter);
  }

  void _end() {
    if (_active != null) setState(() => _active = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final letters = _visibleLetters(height);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Semantics(
              label: 'Section index',
              hint: 'Swipe up or down to jump to a letter',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _handle(d.localPosition.dy, height),
                onTapUp: (_) => _end(),
                onTapCancel: _end,
                onVerticalDragStart: (d) => _handle(d.localPosition.dy, height),
                onVerticalDragUpdate: (d) =>
                    _handle(d.localPosition.dy, height),
                onVerticalDragEnd: (_) => _end(),
                onVerticalDragCancel: _end,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final letter in letters)
                      Expanded(
                        child: Center(
                          child: Text(
                            letter,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: widget.present.contains(letter)
                                  ? primary
                                  : primary.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_active != null)
              Positioned(
                right: 40,
                top: (_activeY - 32).clamp(-8.0, height - 56),
                child: IgnorePointer(
                  child: Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: primary,
                      shape: NautuneStyle.of(context).shape(NautuneRadius.lg),
                      shadows: const [
                        BoxShadow(blurRadius: 12, color: Colors.black26),
                      ],
                    ),
                    child: widget.loading
                        ? CupertinoActivityIndicator(
                            color: theme.colorScheme.onPrimary,
                          )
                        : Text(
                            _active!,
                            style: theme.textTheme.title1.copyWith(
                              color: theme.colorScheme.onPrimary,
                            ),
                          ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
