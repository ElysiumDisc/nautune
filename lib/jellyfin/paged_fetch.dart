/// Pure pagination helpers for Jellyfin `StartIndex`/`Limit` queries.
library;

import 'dart:math';

/// One page of a Jellyfin `QueryResult`: the page's items plus the server's
/// `TotalRecordCount` (null when the server didn't report it).
typedef JellyfinPage<T> = ({List<T> items, int? totalRecordCount});

/// Fetches one page. [random] requests `SortBy=Random`; otherwise the
/// implementation must use a stable server-side order so consecutive
/// `startIndex` windows don't overlap.
typedef JellyfinPageFetcher<T> =
    Future<JellyfinPage<T>> Function({
      required int startIndex,
      required int limit,
      required bool random,
    });

/// Collects up to [limit] distinct items in random order.
///
/// `SortBy=Random` re-shuffles on every request, so paging a random order
/// with `StartIndex` returns overlapping pages (duplicates) and skips items.
/// Instead:
/// - the first random page reveals `TotalRecordCount`;
/// - if the whole library fits in [limit], it is paged in a stable order
///   (no duplicates, nothing skipped) and shuffled client-side;
/// - otherwise independent random pages (`startIndex` 0) are merged and
///   de-duplicated until [limit] items are collected or [maxRandomPages]
///   requests were made.
///
/// Always terminates: every loop is bounded by a request budget and stops
/// on an empty or short page.
Future<List<T>> collectRandomSample<T>({
  required JellyfinPageFetcher<T> fetchPage,
  required String Function(T) idOf,
  required int limit,
  int pageSize = 500,
  int? maxRandomPages,
  Random? random,
}) async {
  if (limit <= 0) return <T>[];
  final rng = random ?? Random();
  final firstLimit = min(limit, pageSize);
  final first = await fetchPage(startIndex: 0, limit: firstLimit, random: true);
  final seen = <String>{};
  final result = <T>[];
  void addAll(Iterable<T> items) {
    for (final item in items) {
      if (result.length >= limit) return;
      if (seen.add(idOf(item))) result.add(item);
    }
  }

  addAll(first.items);
  final total = first.totalRecordCount;
  if (first.items.length < firstLimit ||
      result.length >= limit ||
      (total != null && result.length >= total)) {
    return result; // Library exhausted, or limit reached in one request.
  }

  if (total != null && total <= limit) {
    // Whole library fits: page it in a stable order, then shuffle.
    result.clear();
    seen.clear();
    final pages = collectStablePages<T>(
      fetchPage: ({required int startIndex, required int limit}) =>
          fetchPage(startIndex: startIndex, limit: limit, random: false),
      idOf: idOf,
      limit: limit,
      pageSize: pageSize,
    );
    addAll(await pages);
    result.shuffle(rng);
    return result;
  }

  // Library larger than [limit] (or size unknown): merge random samples.
  final budget = maxRandomPages ?? ((limit / pageSize).ceil() * 2 + 1);
  for (var i = 1; i < budget && result.length < limit; i++) {
    final want = min(pageSize, limit - result.length);
    final page = await fetchPage(startIndex: 0, limit: want, random: true);
    if (page.items.isEmpty) break;
    final before = result.length;
    addAll(page.items);
    if (result.length == before && page.items.length < want) break;
  }
  return result;
}

/// Collects up to [limit] distinct items by paging a *stable* server order.
///
/// Advances `startIndex` by the number of items the server returned and
/// stops on an empty page, when `TotalRecordCount` is reached (or, without
/// a total, on a short page), when a page adds nothing new, or when [limit]
/// items are collected. Duplicates (possible if the library changes
/// mid-scan) are dropped.
Future<List<T>> collectStablePages<T>({
  required Future<JellyfinPage<T>> Function({
    required int startIndex,
    required int limit,
  })
  fetchPage,
  required String Function(T) idOf,
  int? limit,
  int pageSize = 500,
}) async {
  final seen = <String>{};
  final result = <T>[];
  var startIndex = 0;
  int? total;
  // Hard request budget as a last-resort guard against a misbehaving server
  // (e.g. one that ignores StartIndex and keeps returning full pages).
  final maxRequests = limit != null ? (limit / pageSize).ceil() + 2 : 100000;
  for (var request = 0; request < maxRequests; request++) {
    if (limit != null && result.length >= limit) break;
    if (total != null && startIndex >= total) break;
    final want = limit != null
        ? min(pageSize, limit - result.length)
        : pageSize;
    final page = await fetchPage(startIndex: startIndex, limit: want);
    total = page.totalRecordCount ?? total;
    if (page.items.isEmpty) break;
    var added = 0;
    for (final item in page.items) {
      if (limit != null && result.length >= limit) break;
      if (seen.add(idOf(item))) {
        result.add(item);
        added++;
      }
    }
    startIndex += page.items.length;
    // A short page means "end" only when the server gave no total; with a
    // total, keep going until startIndex reaches it (a server may return
    // short pages mid-way, e.g. after access filtering).
    if (total == null && page.items.length < want) break;
    if (added == 0) break; // Server ignored StartIndex: stop, don't spin.
  }
  return result;
}
