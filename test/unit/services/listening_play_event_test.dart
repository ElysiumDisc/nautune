import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/listening_analytics_service.dart';

void main() {
  group('PlayEvent.fromJson', () {
    final base = <String, dynamic>{
      'trackId': 't1',
      'trackName': 'Song',
      'albumId': 'a1',
      'albumName': 'Album',
      'artists': <String>['Artist A', 'Artist B'],
      'genres': <String>['Rock'],
      'timestamp': '2026-05-20T12:34:56.000Z',
      'durationMs': 180000,
      'synced': true,
      'eventId': 'evt-1',
    };

    test('round-trips a fully populated event', () {
      final ev = PlayEvent.fromJson(Map<String, dynamic>.from(base));
      expect(ev.trackId, 't1');
      expect(ev.trackName, 'Song');
      expect(ev.albumId, 'a1');
      expect(ev.albumName, 'Album');
      expect(ev.artists, <String>['Artist A', 'Artist B']);
      expect(ev.genres, <String>['Rock']);
      expect(ev.timestamp.toUtc().toIso8601String(), '2026-05-20T12:34:56.000Z');
      expect(ev.durationMs, 180000);
      expect(ev.synced, true);
      expect(ev.eventId, 'evt-1');
    });

    test('missing `artists` is treated as empty list (no throw)', () {
      // Regression for F1: prior to v8.9.7 the `as List<dynamic>` cast on
      // a missing key threw, and the surrounding bulk try/catch in
      // _loadEvents wiped the whole history.
      final json = Map<String, dynamic>.from(base)..remove('artists');
      final ev = PlayEvent.fromJson(json);
      expect(ev.artists, isEmpty);
    });

    test('null `artists` is treated as empty list (no throw)', () {
      final json = Map<String, dynamic>.from(base);
      json['artists'] = null;
      final ev = PlayEvent.fromJson(json);
      expect(ev.artists, isEmpty);
    });

    test('missing `genres` is treated as empty list (regression guard)', () {
      final json = Map<String, dynamic>.from(base)..remove('genres');
      final ev = PlayEvent.fromJson(json);
      expect(ev.genres, isEmpty);
    });

    test('missing optional fields use safe defaults', () {
      final json = Map<String, dynamic>.from(base)
        ..remove('albumId')
        ..remove('albumName')
        ..remove('durationMs')
        ..remove('synced')
        ..remove('eventId');
      final ev = PlayEvent.fromJson(json);
      expect(ev.albumId, isNull);
      expect(ev.albumName, isNull);
      expect(ev.durationMs, 0);
      expect(ev.synced, false);
      // PlayEvent's constructor auto-generates a deterministic eventId
      // from (trackId, timestampMs) when one isn't supplied.
      expect(ev.eventId, '${ev.trackId}_${ev.timestamp.millisecondsSinceEpoch}');
    });
  });
}
