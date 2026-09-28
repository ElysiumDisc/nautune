/// Pure A-Z index logic for the library lists: grouping items into letter
/// sections and computing exactly where each section starts, so the index
/// strip lands on the right letter however large the library is.
library;

/// Letters on the index strip, in ascending order.
const List<String> kIndexLetters = [
  '#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

const Map<String, String> _accentMap = {
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

/// Index letter for [name]: its first character as A-Z (accents folded),
/// or `#` for digits, symbols and other scripts.
String indexLetterFor(String name) {
  final trimmed = name.trimLeft();
  if (trimmed.isEmpty) return '#';
  final first = trimmed.substring(0, 1).toUpperCase();
  final code = first.codeUnitAt(0);
  if (code >= 65 && code <= 90) return first;
  return _accentMap[first] ?? '#';
}

/// Position of [letter] on the strip (`#` first).
int indexLetterRank(String letter) {
  final i = kIndexLetters.indexOf(letter);
  return i < 0 ? 0 : i;
}

class LetterSection<T> {
  const LetterSection(this.letter, this.items);
  final String letter;
  final List<T> items;
}

/// Groups [items] into letter sections in scroll order ([ascending] puts `#`
/// first, descending puts it last). Items keep their order within a section.
List<LetterSection<T>> sectionsByLetter<T>(
  List<T> items,
  String Function(T item) nameOf, {
  required bool ascending,
}) {
  final groups = <String, List<T>>{};
  for (final item in items) {
    groups.putIfAbsent(indexLetterFor(nameOf(item)), () => []).add(item);
  }
  final letters = groups.keys.toList()
    ..sort((a, b) {
      final cmp = indexLetterRank(a).compareTo(indexLetterRank(b));
      return ascending ? cmp : -cmp;
    });
  return [for (final l in letters) LetterSection(l, groups[l]!)];
}

/// Fixed geometry of one letter section, matching the slivers that render
/// it: a header, then [columns] items per row of [itemExtent] separated by
/// [rowSpacing], padded by [paddingTop] / [paddingBottom].
class SectionGeometry {
  const SectionGeometry({
    required this.headerExtent,
    required this.itemExtent,
    this.columns = 1,
    this.rowSpacing = 0,
    this.paddingTop = 0,
    this.paddingBottom = 0,
  });

  final double headerExtent;
  final double itemExtent;
  final int columns;
  final double rowSpacing;
  final double paddingTop;
  final double paddingBottom;

  double extentFor(int itemCount) {
    final rows = (itemCount / columns).ceil();
    final body = rows * itemExtent + (rows > 0 ? (rows - 1) * rowSpacing : 0);
    return headerExtent + paddingTop + body + paddingBottom;
  }
}

/// Scroll offset where each section's header starts, after [leading] pixels
/// of content above the first section.
Map<String, double> sectionOffsets<T>(
  List<LetterSection<T>> sections,
  SectionGeometry geometry, {
  double leading = 0,
}) {
  final offsets = <String, double>{};
  var y = leading;
  for (final s in sections) {
    offsets[s.letter] = y;
    y += geometry.extentFor(s.items.length);
  }
  return offsets;
}

/// Section to show for a tap on [target]: the letter itself, else the next
/// present letter in scroll direction, else the last section. Null when
/// there are no sections.
String? resolveIndexLetter(
  String target,
  List<String> present, {
  required bool ascending,
}) {
  if (present.isEmpty) return null;
  if (present.contains(target)) return target;
  final rank = indexLetterRank(target);
  for (final l in present) {
    final r = indexLetterRank(l);
    if (ascending ? r > rank : r < rank) return l;
  }
  return present.last;
}

/// Whether [target] would come after every loaded section, so it may be in
/// pages that haven't been fetched yet.
bool letterBeyondLoaded(
  String target,
  List<String> present, {
  required bool ascending,
}) {
  if (present.contains(target)) return false;
  if (present.isEmpty) return true;
  final last = indexLetterRank(present.last);
  final rank = indexLetterRank(target);
  return ascending ? rank > last : rank < last;
}
