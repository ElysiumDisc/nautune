/// Reorders [items] to follow the order of [ids].
///
/// Jellyfin's `/Items?ids=…` returns results in its own sort order, not the
/// requested order. Ids with no matching item are skipped; ids repeated in
/// [ids] yield the matching item once per occurrence (queues can contain the
/// same track twice). Items whose id wasn't requested are dropped.
List<T> orderByIds<T>(
  List<String> ids,
  Iterable<T> items,
  String Function(T item) idOf,
) {
  final byId = <String, T>{};
  for (final item in items) {
    byId.putIfAbsent(idOf(item), () => item);
  }
  final ordered = <T>[];
  for (final id in ids) {
    final item = byId[id];
    if (item != null) ordered.add(item);
  }
  return ordered;
}

/// Default number of ids per `Ids=` query. ~33 bytes per id keeps the
/// request line well under Kestrel's 8 KB `MaxRequestLineSize` (and nginx's
/// default 8 KB header buffer) even with the other query parameters.
const int kMaxIdsPerRequest = 100;

/// Splits [ids] into consecutive chunks of at most [size] ids, preserving
/// order (duplicates are kept). Empty input yields no chunks.
List<List<String>> chunkIds(List<String> ids, {int size = kMaxIdsPerRequest}) {
  if (size <= 0) throw ArgumentError.value(size, 'size', 'must be positive');
  return [
    for (var i = 0; i < ids.length; i += size)
      ids.sublist(i, i + size > ids.length ? ids.length : i + size),
  ];
}
