import 'dart:math';

import 'package:flutter/material.dart';

import '../tui_metrics.dart';
import '../tui_theme.dart';

/// State for a TUI list with cursor and scroll management.
class TuiListState<T> extends ChangeNotifier {
  TuiListState({
    List<T>? items,
    this.visibleRows = 20,
  }) : _items = items ?? [];

  List<T> _items;
  int _cursorIndex = 0;
  int _scrollOffset = 0;
  int visibleRows;

  List<T> get items => _items;
  int get cursorIndex => _cursorIndex;
  int get scrollOffset => _scrollOffset;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  T? get selectedItem =>
      _items.isNotEmpty && _cursorIndex < _items.length ? _items[_cursorIndex] : null;

  void setItems(List<T> newItems) {
    _items = newItems;
    // Clamp cursor to valid range
    if (_items.isEmpty) {
      _cursorIndex = 0;
      _scrollOffset = 0;
    } else {
      _cursorIndex = _cursorIndex.clamp(0, _items.length - 1);
      _adjustScroll();
    }
    notifyListeners();
  }

  void moveUp() {
    if (_items.isEmpty) return;
    _cursorIndex = max(0, _cursorIndex - 1);
    _adjustScroll();
    notifyListeners();
  }

  void moveDown() {
    if (_items.isEmpty) return;
    _cursorIndex = min(_items.length - 1, _cursorIndex + 1);
    _adjustScroll();
    notifyListeners();
  }

  void goToTop() {
    if (_items.isEmpty) return;
    _cursorIndex = 0;
    _scrollOffset = 0;
    notifyListeners();
  }

  void goToBottom() {
    if (_items.isEmpty) return;
    _cursorIndex = _items.length - 1;
    _adjustScroll();
    notifyListeners();
  }

  void pageUp() {
    if (_items.isEmpty) return;
    _cursorIndex = max(0, _cursorIndex - visibleRows);
    _adjustScroll();
    notifyListeners();
  }

  void pageDown() {
    if (_items.isEmpty) return;
    _cursorIndex = min(_items.length - 1, _cursorIndex + visibleRows);
    _adjustScroll();
    notifyListeners();
  }

  void selectIndex(int index) {
    if (_items.isEmpty || index < 0 || index >= _items.length) return;
    _cursorIndex = index;
    _adjustScroll();
    notifyListeners();
  }

  void _adjustScroll() {
    // Keep cursor visible within the viewport
    if (_cursorIndex < _scrollOffset) {
      _scrollOffset = _cursorIndex;
    } else if (_cursorIndex >= _scrollOffset + visibleRows) {
      _scrollOffset = _cursorIndex - visibleRows + 1;
    }
    // Clamp scroll offset
    final maxOffset = max(0, _items.length - visibleRows);
    _scrollOffset = _scrollOffset.clamp(0, maxOffset);
  }

  /// Returns the visible items based on current scroll position.
  List<T> get visibleItems {
    if (_items.isEmpty) return [];
    final end = min(_scrollOffset + visibleRows, _items.length);
    return _items.sublist(_scrollOffset, end);
  }

  /// Returns true if the given index is the cursor position.
  bool isCursor(int visibleIndex) {
    return (_scrollOffset + visibleIndex) == _cursorIndex;
  }

  /// Returns the actual list index for a visible index.
  int actualIndex(int visibleIndex) => _scrollOffset + visibleIndex;
}

/// A scrollable list widget with vim-style cursor selection.
class TuiList<T> extends StatelessWidget {
  const TuiList({
    super.key,
    required this.state,
    required this.itemBuilder,
    this.emptyMessage = 'No items',
    this.playingIndex,
  });

  final TuiListState<T> state;
  final Widget Function(BuildContext context, T item, int index, bool isSelected, bool isPlaying) itemBuilder;
  final String emptyMessage;
  final int? playingIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate visible rows based on available height
        // Subtract 1 to prevent overflow from rounding errors
        final availableHeight = constraints.maxHeight;
        final rowHeight = TuiMetrics.charHeight;
        final calculatedRows = max(1, (availableHeight / rowHeight).floor() - 1);

        // Update state with calculated visible rows
        if (state.visibleRows != calculatedRows && calculatedRows > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            state.visibleRows = calculatedRows;
            // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
            state.notifyListeners();
          });
        }

        return ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            if (state.isEmpty) {
              return Center(
                child: Text(emptyMessage, style: TuiTextStyles.dim),
              );
            }

            final visibleItems = state.visibleItems;

            return ClipRect(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < visibleItems.length; i++)
                    SizedBox(
                      height: rowHeight,
                      child: itemBuilder(
                        context,
                        visibleItems[i],
                        state.actualIndex(i),
                        state.isCursor(i),
                        playingIndex != null && state.actualIndex(i) == playingIndex,
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// A single list item row with selection styling.
class TuiListItem extends StatelessWidget {
  const TuiListItem({
    super.key,
    required this.text,
    this.isSelected = false,
    this.isPlaying = false,
    this.prefix,
    this.suffix,
    this.onTap,
  });

  final String text;
  final bool isSelected;
  final bool isPlaying;
  final String? prefix;
  final String? suffix;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle style;
    if (isSelected) {
      style = TuiTextStyles.selection;
    } else if (isPlaying) {
      style = TuiTextStyles.playing;
    } else {
      style = TuiTextStyles.normal;
    }

    final prefixText = isSelected
        ? '${TuiChars.cursor} '
        : isPlaying
            ? '${TuiChars.playing} '
            : prefix ?? '  ';

    final suffixText = suffix ?? '';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: isSelected ? TuiColors.selection : Colors.transparent,
        child: Row(
          children: [
            Text(prefixText, style: style),
            Expanded(
              child: Text(
                text,
                style: style,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (suffixText.isNotEmpty)
              Text(' $suffixText', style: style.copyWith(color: TuiColors.dim)),
          ],
        ),
      ),
    );
  }
}
