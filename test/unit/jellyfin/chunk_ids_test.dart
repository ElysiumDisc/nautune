import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/order_by_ids.dart';

void main() {
  test('chunks preserve order and cover every id', () {
    final ids = [for (var i = 0; i < 250; i++) 'id$i'];
    final chunks = chunkIds(ids);
    expect(chunks.map((c) => c.length), [100, 100, 50]);
    expect(chunks.expand((c) => c), ids);
  });

  test('empty input yields no chunks; exact multiple has no empty tail', () {
    expect(chunkIds(const []), isEmpty);
    expect(chunkIds(List.filled(200, 'x')).length, 2);
    expect(chunkIds(const ['a', 'b', 'c'], size: 2), [
      ['a', 'b'],
      ['c'],
    ]);
  });

  test('rejects a non-positive size', () {
    expect(() => chunkIds(const ['a'], size: 0), throwsArgumentError);
  });
}
