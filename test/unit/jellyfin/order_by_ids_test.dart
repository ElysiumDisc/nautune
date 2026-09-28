import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/order_by_ids.dart';

void main() {
  String idOf(String s) => s.split(':').first;

  test('reorders to match requested ids', () {
    final result = orderByIds(['c', 'a', 'b'], ['a:1', 'b:2', 'c:3'], idOf);
    expect(result, ['c:3', 'a:1', 'b:2']);
  });

  test('skips missing ids and drops unrequested items', () {
    final result = orderByIds(['x', 'b', 'a'], ['a:1', 'b:2', 'z:9'], idOf);
    expect(result, ['b:2', 'a:1']);
  });

  test('repeats items for duplicate requested ids', () {
    final result = orderByIds(['a', 'b', 'a'], ['b:2', 'a:1'], idOf);
    expect(result, ['a:1', 'b:2', 'a:1']);
  });

  test('empty inputs', () {
    expect(orderByIds<String>([], ['a:1'], idOf), isEmpty);
    expect(orderByIds<String>(['a'], [], idOf), isEmpty);
  });
}
