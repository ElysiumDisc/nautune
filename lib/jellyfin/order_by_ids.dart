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
