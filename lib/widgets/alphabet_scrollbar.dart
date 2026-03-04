part of '../screens/library_screen.dart';

/// Section header widget for alphabet groups
class _AlphabetSectionHeader extends StatelessWidget {
  const _AlphabetSectionHeader({required this.letter});
  final String letter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(
        letter,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Helper to build a flat list with section headers for SliverList
class AlphabetSectionBuilder {
  AlphabetSectionBuilder._();

  /// Normalizes accented characters to their base A-Z letter.
  /// E.g., 'É' → 'E', 'Ñ' → 'N', 'Ü' → 'U'
  static String normalizeToBaseLetter(String char) {
    if (char.isEmpty) return '#';
    final code = char.codeUnitAt(0);

    // Already a standard A-Z letter
    if (code >= 65 && code <= 90) return char;

    // Already a digit
    if (code >= 48 && code <= 57) return '#';

    // Map common accented characters to base letters
    const accentMap = {
      'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A', 'Ă': 'A', 'Ą': 'A',
      'Ç': 'C', 'Ć': 'C', 'Č': 'C',
      'Ď': 'D', 'Đ': 'D',
      'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E', 'Ě': 'E', 'Ę': 'E',
      'Ğ': 'G',
      'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I', 'İ': 'I',
      'Ł': 'L',
      'Ñ': 'N', 'Ń': 'N', 'Ň': 'N',
      'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ø': 'O', 'Ő': 'O',
      'Ř': 'R',
      'Ś': 'S', 'Ş': 'S', 'Š': 'S',
      'Ť': 'T', 'Ţ': 'T',
      'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U', 'Ů': 'U', 'Ű': 'U',
      'Ý': 'Y', 'Ÿ': 'Y',
      'Ź': 'Z', 'Ż': 'Z', 'Ž': 'Z',
      'Æ': 'A', 'Œ': 'O', 'Þ': 'T', 'Ð': 'D',
    };

    return accentMap[char] ?? '#';
  }

  /// Groups items by first letter and returns a list of (letter, items) pairs
  static List<(String, List<T>)> groupByLetter<T>(
    List<T> items,
    String Function(T) getItemName,
    SortOrder sortOrder,
  ) {
    if (items.isEmpty) return [];

    final isAscending = sortOrder == SortOrder.ascending;

    // Group items by first letter (normalized to base A-Z)
    final Map<String, List<T>> letterGroups = {};
    for (final item in items) {
      final name = getItemName(item).toUpperCase();
      if (name.isEmpty) continue;
      final firstChar = name[0];
      final letter = RegExp(r'[0-9]').hasMatch(firstChar)
          ? '#'
          : normalizeToBaseLetter(firstChar);
      letterGroups.putIfAbsent(letter, () => []).add(item);
    }

    // Sort letters
    final sortedLetters = letterGroups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return isAscending ? -1 : 1;
        if (b == '#') return isAscending ? 1 : -1;
        return isAscending ? a.compareTo(b) : b.compareTo(a);
      });

    return sortedLetters.map((letter) => (letter, letterGroups[letter]!)).toList();
  }
}

/// Helper class to map letters to their positions in a list with section headers
class LetterPositions {
  LetterPositions._();

  /// Build a map of letter -> flat index accounting for section headers
  /// Returns (letterToFlatIndex, totalItemCount including headers)
  static (Map<String, int>, int) buildWithHeaders(
    List items,
    String Function(dynamic) getItemName,
    SortOrder sortOrder,
  ) {
    if (items.isEmpty) return ({}, 0);

    final Map<String, int> letterToIndex = {};
    final isAscending = sortOrder == SortOrder.ascending;

    // Group items by first letter
    final Map<String, List<int>> letterGroups = {};
    for (int i = 0; i < items.length; i++) {
      final name = getItemName(items[i]).toUpperCase();
      if (name.isEmpty) continue;
      final firstChar = name[0];
      final letter = RegExp(r'[0-9]').hasMatch(firstChar) ? '#' : firstChar;
      letterGroups.putIfAbsent(letter, () => []).add(i);
    }

    // Sort letters appropriately
    final sortedLetters = letterGroups.keys.toList()
      ..sort((a, b) {
        // # comes first in ascending, last in descending
        if (a == '#') return isAscending ? -1 : 1;
        if (b == '#') return isAscending ? 1 : -1;
        return isAscending ? a.compareTo(b) : b.compareTo(a);
      });

    // Calculate flat positions (each letter group adds 1 header)
    int flatIndex = 0;
    for (final letter in sortedLetters) {
      letterToIndex[letter] = flatIndex;
      flatIndex++; // The header
      flatIndex += letterGroups[letter]!.length; // The items
    }

    return (letterToIndex, flatIndex);
  }

  /// Get the letter for an item at a given index
  static String getLetterForItem(dynamic item, String Function(dynamic) getItemName) {
    final name = getItemName(item).toUpperCase();
    if (name.isEmpty) return '#';
    final firstChar = name[0];
    return RegExp(r'[0-9]').hasMatch(firstChar) ? '#' : firstChar;
  }
}

// Alphabet scrollbar for quick navigation
class AlphabetScrollbar extends StatefulWidget {
  const AlphabetScrollbar({
    super.key,
    required this.items,
    required this.getItemName,
    required this.scrollController,
    required this.itemHeight,
    required this.crossAxisCount,
    this.sortOrder = SortOrder.ascending,
    this.sortBy,
    this.headerHeight = 40.0,
    this.useHeaders = true,
  });

  final List items;
  final String Function(dynamic) getItemName;
  final ScrollController scrollController;
  final double itemHeight;
  final int crossAxisCount;
  final SortOrder sortOrder;
  final SortOption? sortBy;
  final double headerHeight;
  final bool useHeaders;

  @override
  State<AlphabetScrollbar> createState() => _AlphabetScrollbarState();
}

class _AlphabetScrollbarState extends State<AlphabetScrollbar> {
  static const _alphabet = ['#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I',
                             'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S',
                             'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];

  String? _activeLetter;
  double _bubbleY = 0.0;

  // Build a map from first letter to scroll position for fast lookup
  // Returns (letterToPosition, totalHeight)
  (Map<String, double>, double) _buildLetterPositions() {
    final Map<String, double> letterToPosition = {};
    final isAscending = widget.sortOrder == SortOrder.ascending;

    // Group items by first letter (normalized to base A-Z)
    final Map<String, List<int>> letterGroups = {};
    for (int i = 0; i < widget.items.length; i++) {
      final name = widget.getItemName(widget.items[i]).toUpperCase();
      if (name.isEmpty) continue;
      final firstChar = name[0];
      // Use normalizer to map accented chars to base letters
      final letter = RegExp(r'[0-9]').hasMatch(firstChar)
          ? '#'
          : AlphabetSectionBuilder.normalizeToBaseLetter(firstChar);
      letterGroups.putIfAbsent(letter, () => []).add(i);
    }

    // Sort letters appropriately
    final sortedLetters = letterGroups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return isAscending ? -1 : 1;
        if (b == '#') return isAscending ? 1 : -1;
        return isAscending ? a.compareTo(b) : b.compareTo(a);
      });

    // Calculate scroll positions accounting for headers
    // Grid mode (crossAxisCount > 1): no initial padding, first header at 0
    // List mode (crossAxisCount == 1): 8px initial padding from SliverPadding
    final isListMode = widget.crossAxisCount == 1;
    double currentPosition = isListMode ? 8.0 : 0.0;

    for (final letter in sortedLetters) {
      letterToPosition[letter] = currentPosition;
      currentPosition += widget.headerHeight; // Header (40px)
      final itemCount = letterGroups[letter]!.length;
      final rowCount = (itemCount / widget.crossAxisCount).ceil();
      currentPosition += rowCount * widget.itemHeight;
      // Account for SliverPadding(vertical: 8) = 16px per group in grid mode
      if (widget.crossAxisCount > 1) {
        currentPosition += 16.0;
      }
    }

    // Add bottom padding
    currentPosition += 100.0;

    return (letterToPosition, currentPosition);
  }

  void _scrollToLetter(String letter) {
    if (widget.items.isEmpty) return;
    if (!widget.scrollController.hasClients) return;

    final (letterPositions, totalHeight) = _buildLetterPositions();
    double targetPosition;

    // Direct match
    if (letterPositions.containsKey(letter)) {
      targetPosition = letterPositions[letter]!;
    } else {
      // No exact match - find nearest letter
      final isAscending = widget.sortOrder == SortOrder.ascending;

      if (letter == '#') {
        // Looking for numbers but none found - go to start/end
        targetPosition = isAscending ? 0.0 : totalHeight;
      } else {
        // Find the closest available letter
        final letterCode = letter.codeUnitAt(0);
        String? bestMatch;
        final sortedKeys = letterPositions.keys.toList()
          ..sort((a, b) {
            if (a == '#') return isAscending ? -1 : 1;
            if (b == '#') return isAscending ? 1 : -1;
            return isAscending ? a.compareTo(b) : b.compareTo(a);
          });

        // Filter to only standard A-Z letters for fallback (ignore accented chars like Á, †, etc.)
        final standardKeys = sortedKeys.where((k) => k == '#' || (k.codeUnitAt(0) >= 65 && k.codeUnitAt(0) <= 90)).toList();

        if (isAscending) {
          // Ascending: Find first existing letter >= target
          for (final key in standardKeys) {
            if (key == '#') continue;
            if (key.codeUnitAt(0) >= letterCode) {
              bestMatch = key;
              break;
            }
          }
        } else {
          // Descending: Find first existing letter <= target
          for (final key in standardKeys) {
            if (key == '#') continue;
            if (key.codeUnitAt(0) <= letterCode) {
              bestMatch = key;
              break;
            }
          }
        }

        if (bestMatch != null) {
          targetPosition = letterPositions[bestMatch]!;
        } else {
          // If no letter found after target (e.g. target Z, only have A-Y), go to end
          // Use calculated totalHeight instead of maxScrollExtent which might be inaccurate
          targetPosition = isAscending ? totalHeight : 0.0;
        }
      }
    }

    // Ensure we don't scroll before the start
    // We do NOT clamp to maxScrollExtent because in List View (SliverList),
    // the maxExtent might be estimated and much smaller than the real content height.
    // Jumping to the calculated position usually forces the list to build and update the extent.
    final safePosition = targetPosition < 0.0 ? 0.0 : targetPosition;

    // Use jumpTo during drag for immediate response
    if (_activeLetter != null) {
      widget.scrollController.jumpTo(safePosition);
    } else {
      widget.scrollController.animateTo(
        safePosition,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _handleInput(Offset localPosition, double height, List<String> displayLetters) {
    // Divide touch area into N equal zones
    // Zone i covers y from i*H/N to (i+1)*H/N
    final int index = (localPosition.dy * displayLetters.length / height)
        .floor()
        .clamp(0, displayLetters.length - 1);
    final String letter = displayLetters[index];

    if (_activeLetter != letter) {
      setState(() {
        _activeLetter = letter;
        _bubbleY = localPosition.dy.clamp(20, height - 80);
      });
      _scrollToLetter(letter);
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hide scrollbar when not sorting by name (letters don't match content)
    if (widget.sortBy != null && widget.sortBy != SortOption.name) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The Touch Strip
        Positioned(
          right: 0,
          top: 40,
          bottom: 40,
          width: 30,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight = constraints.maxHeight;
              final letterHeight = 16.0;
              final maxLetters = (availableHeight / letterHeight).floor();

              // If not enough space for all letters, show subset
              List<String> displayLetters = _alphabet;
              if (maxLetters < _alphabet.length && maxLetters > 0) {
                final step = (_alphabet.length / maxLetters).ceil();
                displayLetters = [];
                for (int i = 0; i < _alphabet.length; i += step) {
                  displayLetters.add(_alphabet[i]);
                }
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => _handleInput(details.localPosition, constraints.maxHeight, displayLetters),
                onVerticalDragStart: (details) => _handleInput(details.localPosition, constraints.maxHeight, displayLetters),
                onVerticalDragUpdate: (details) => _handleInput(details.localPosition, constraints.maxHeight, displayLetters),
                onVerticalDragEnd: (_) => setState(() => _activeLetter = null),
                onTapUp: (_) => setState(() => _activeLetter = null),
                child: Container(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: displayLetters.map((letter) {
                      final isActive = _activeLetter == letter;
                      return Flexible(
                        child: AnimatedScale(
                          scale: isActive ? 1.4 : 1.0,
                          duration: const Duration(milliseconds: 100),
                          child: Text(
                            letter,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isActive ? FontWeight.w900 : FontWeight.w600,
                              color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          ),
        ),

        // The Pop Out Bubble
        if (_activeLetter != null)
           Positioned(
             right: 50,
             top: _bubbleY + 40, // Offset to match touch strip positioning
             child: Container(
               width: 60, height: 60,
               alignment: Alignment.center,
               decoration: BoxDecoration(
                 color: theme.colorScheme.primaryContainer,
                 shape: BoxShape.circle,
                 boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
               ),
               child: Text(
                 _activeLetter!,
                 style: TextStyle(
                   fontSize: 32,
                   fontWeight: FontWeight.bold,
                   color: theme.colorScheme.onPrimaryContainer
                 ),
               ),
             ),
           ),
      ],
    );
  }
}
