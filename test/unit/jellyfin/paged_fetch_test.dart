import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/paged_fetch.dart';

/// Fake Jellyfin `/Items` over [total] items (ids "0".."total-1").
/// Random requests reshuffle on every call, like `SortBy=Random`.
class _FakeServer {
  _FakeServer(this.total, {this.ignoreStartIndex = false, int seed = 1})
    : _rng = Random(seed);

  final int total;
  final bool ignoreStartIndex;
  final Random _rng;
  final List<({int startIndex, int limit, bool random})> requests = [];

  Future<JellyfinPage<String>> page({
    required int startIndex,
    required int limit,
    bool random = false,
  }) async {
    requests.add((startIndex: startIndex, limit: limit, random: random));
    final all = List.generate(total, (i) => '$i');
    if (random) all.shuffle(_rng);
    final from = ignoreStartIndex ? 0 : min(startIndex, total);
    final to = min(from + limit, total);
    return (items: all.sublist(from, to), totalRecordCount: total);
  }
}

void main() {
  group('collectRandomSample', () {
    test('small library: one request, everything, no duplicates', () async {
      final server = _FakeServer(120);
      final result = await collectRandomSample<String>(
        fetchPage: server.page,
        idOf: (s) => s,
        limit: 5000,
      );
      expect(result.toSet().length, 120);
      expect(result.length, 120);
      expect(server.requests, hasLength(1));
    });

    test(
      'library <= limit but > page size: stable paging, complete, shuffled',
      () async {
        final server = _FakeServer(1234);
        final result = await collectRandomSample<String>(
          fetchPage: server.page,
          idOf: (s) => s,
          limit: 5000,
          pageSize: 500,
          random: Random(7),
        );
        expect(result.length, 1234);
        expect(result.toSet().length, 1234, reason: 'no duplicates');
        // First probe is random, the full scan is stable (non-random).
        expect(server.requests.first.random, isTrue);
        expect(server.requests.skip(1).every((r) => !r.random), isTrue);
        expect(server.requests.skip(1).map((r) => r.startIndex), [
          0,
          500,
          1000,
        ]);
        // Client-side shuffle: not in server order.
        expect(result.take(20).toList(), isNot(List.generate(20, (i) => '$i')));
      },
    );

    test(
      'large library: distinct sample of exactly limit, bounded requests',
      () async {
        final server = _FakeServer(50000);
        final result = await collectRandomSample<String>(
          fetchPage: server.page,
          idOf: (s) => s,
          limit: 5000,
          pageSize: 500,
        );
        expect(result.length, 5000);
        expect(result.toSet().length, 5000);
        expect(server.requests.length, lessThanOrEqualTo(21));
        expect(
          server.requests.every((r) => r.random && r.startIndex == 0),
          isTrue,
        );
      },
    );

    test(
      'library slightly larger than limit terminates within budget',
      () async {
        final server = _FakeServer(600);
        final result = await collectRandomSample<String>(
          fetchPage: server.page,
          idOf: (s) => s,
          limit: 550,
          pageSize: 500,
        );
        expect(result.toSet().length, result.length);
        expect(result.length, lessThanOrEqualTo(550));
        expect(result.length, greaterThan(500));
        expect(server.requests.length, lessThanOrEqualTo(5));
      },
    );

    test('empty library and zero limit', () async {
      final server = _FakeServer(0);
      expect(
        await collectRandomSample<String>(
          fetchPage: server.page,
          idOf: (s) => s,
          limit: 10,
        ),
        isEmpty,
      );
      expect(
        await collectRandomSample<String>(
          fetchPage: server.page,
          idOf: (s) => s,
          limit: 0,
        ),
        isEmpty,
      );
    });
  });

  group('collectStablePages', () {
    test('pages until TotalRecordCount', () async {
      final server = _FakeServer(1001);
      final result = await collectStablePages<String>(
        fetchPage: ({required int startIndex, required int limit}) =>
            server.page(startIndex: startIndex, limit: limit),
        idOf: (s) => s,
        pageSize: 500,
      );
      expect(result, List.generate(1001, (i) => '$i'));
      expect(server.requests.map((r) => r.startIndex), [0, 500, 1000]);
    });

    test('exact multiple of the page size stops on TotalRecordCount', () async {
      final server = _FakeServer(1000);
      final result = await collectStablePages<String>(
        fetchPage: ({required int startIndex, required int limit}) =>
            server.page(startIndex: startIndex, limit: limit),
        idOf: (s) => s,
        pageSize: 500,
      );
      expect(result.length, 1000);
      expect(server.requests, hasLength(2));
    });

    test('respects limit', () async {
      final server = _FakeServer(5000);
      final result = await collectStablePages<String>(
        fetchPage: ({required int startIndex, required int limit}) =>
            server.page(startIndex: startIndex, limit: limit),
        idOf: (s) => s,
        limit: 750,
        pageSize: 500,
      );
      expect(result.length, 750);
      expect(server.requests.map((r) => r.limit), [500, 250]);
    });

    test(
      'short page mid-way does not truncate when a total is known',
      () async {
        var call = 0;
        final result = await collectStablePages<String>(
          fetchPage: ({required int startIndex, required int limit}) async {
            call++;
            // Server returns 3 items for the first page despite limit 5.
            final n = call == 1 ? 3 : limit;
            final items = [
              for (var i = startIndex; i < startIndex + n && i < 10; i++) '$i',
            ];
            return (items: items, totalRecordCount: 10);
          },
          idOf: (s) => s,
          pageSize: 5,
        );
        expect(result, List.generate(10, (i) => '$i'));
      },
    );

    test(
      'server that ignores StartIndex cannot cause an endless loop',
      () async {
        final server = _FakeServer(5000, ignoreStartIndex: true);
        final result = await collectStablePages<String>(
          fetchPage: ({required int startIndex, required int limit}) =>
              server.page(startIndex: startIndex, limit: limit),
          idOf: (s) => s,
          pageSize: 500,
        );
        expect(result.length, 500);
        expect(server.requests, hasLength(2));
      },
    );
  });
}
