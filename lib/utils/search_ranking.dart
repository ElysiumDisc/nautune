/// Picks the "Top result" for a search: the item whose name best matches
/// the query. Pure so it can be unit-tested.
library;

/// How well [name] matches [query] (case-insensitive): 4 exact, 3 prefix,
/// 2 a word starts with it, 1 contains it, 0 no match.
int searchMatchScore(String name, String query) {
  final n = name.toLowerCase().trim();
  final q = query.toLowerCase().trim();
  if (q.isEmpty || n.isEmpty) return 0;
  if (n == q) return 4;
  if (n.startsWith(q)) return 3;
  if (n.split(RegExp(r'[\s\-_/(&,.]+')).any((w) => w.startsWith(q))) return 2;
  if (n.contains(q)) return 1;
  return 0;
}

enum SearchKind { artist, album, track }

class SearchCandidate<T> {
  const SearchCandidate(this.kind, this.name, this.item);
  final SearchKind kind;
  final String name;
  final T item;
}

/// Best candidate for [query], or null when nothing matches by name. Ties
/// go to artists, then albums, then tracks (the broader result), then to
/// the server's order.
SearchCandidate<T>? topSearchResult<T>(
  String query,
  List<SearchCandidate<T>> candidates,
) {
  SearchCandidate<T>? best;
  var bestScore = 0;
  for (final c in candidates) {
    final score = searchMatchScore(c.name, query);
    if (score > bestScore ||
        (score == bestScore &&
            score > 0 &&
            best != null &&
            c.kind.index < best.kind.index)) {
      best = c;
      bestScore = score;
    }
  }
  return best;
}
