import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/services/pending_report_store.dart';
import 'package:nautune/services/playback_reporting_service.dart';

class _Req {
  _Req(this.path, this.body, this.headers);
  final String path;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

JellyfinTrack _track(String id) => JellyfinTrack(
      id: id,
      name: 'Track $id',
      album: null,
      artists: const [],
      serverUrl: 'https://host/jf',
      token: 'tok',
      userId: 'u',
    );

class _MemoryStore implements PendingReportStore {
  final Map<String, List<Map<String, dynamic>>> data = {};
  @override
  Future<List<Map<String, dynamic>>> load(String key) async =>
      [...?data[key]];
  @override
  Future<void> save(String key, List<Map<String, dynamic>> events) async =>
      data[key] = [...events];
}

void main() {
  late List<_Req> requests;
  late Map<String, Completer<void>> gates;

  PlaybackReportingService build() {
    requests = [];
    gates = {};
    final client = MockClient((request) async {
      final req = _Req(
        request.url.path,
        jsonDecode(request.body) as Map<String, dynamic>,
        request.headers,
      );
      requests.add(req);
      final gate = gates['${req.path}:${req.body['ItemId']}'];
      if (gate != null) await gate.future;
      return http.Response('', 204);
    });
    return PlaybackReportingService(
      serverUrl: 'https://host/jf',
      accessToken: 'tok',
      deviceId: 'dev',
      userId: 'u',
      httpClient: client,
    );
  }

  test('uses sub-path URLs and modern Authorization header', () async {
    final service = build();
    await service.reportPlaybackStart(_track('a'));
    expect(requests.single.path, '/jf/Sessions/Playing');
    expect(requests.single.headers['Authorization'], contains('Token="tok"'));
    expect(requests.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-emby-token')));
    service.dispose();
  });

  test('bodies use only PlaybackStart/Progress/StopInfo fields', () async {
    final service = build();
    final t = _track('a');
    await service.reportPlaybackStart(t, sessionId: 's1', playMethod: 'Transcode');
    await service.reportPlaybackProgress(t, const Duration(seconds: 3), true);
    await service.reportPlaybackStopped(t, const Duration(seconds: 4));
    final start = requests[0].body;
    final progress = requests[1].body;
    final stop = requests[2].body;
    const startInfo = {
      'ItemId', 'MediaSourceId', 'PlaySessionId', 'PlayMethod', 'CanSeek',
      'IsPaused', 'IsMuted', 'PositionTicks', 'RepeatMode',
    };
    expect(start.keys.toSet(), startInfo);
    expect(progress.keys.toSet(), startInfo);
    expect(stop.keys.toSet(),
        {'ItemId', 'MediaSourceId', 'PlaySessionId', 'PositionTicks'});
    expect(start['PlaySessionId'], 's1');
    expect(start['MediaSourceId'], 'a');
    expect(progress['PositionTicks'], 30000000);
    expect(progress['IsPaused'], isTrue);
    expect(progress['PlayMethod'], 'Transcode');
    expect(stop['PositionTicks'], 40000000);
    expect(stop['PlaySessionId'], 's1');
    service.dispose();
  });

  test('a stalled server does not block reporting forever', () async {
    final service = PlaybackReportingService(
      serverUrl: 'https://host/jf',
      accessToken: 'tok',
      deviceId: 'dev',
      userId: 'u',
      httpClient: MockClient((_) => Completer<http.Response>().future),
    );
    fakeAsync((async) {
      var done = false;
      service.reportPlaybackStart(_track('a')).then((_) => done = true);
      async.elapse(const Duration(seconds: 14));
      expect(done, isFalse);
      // The 15 s request timeout fires; the error is swallowed.
      async.elapse(const Duration(seconds: 2));
      expect(done, isTrue);
      service.dispose();
    });
  });

  group('progress cadence', () {
    Duration? cadence({bool paused = false, bool bg = false, int base = 10}) =>
        PlaybackReportingService.progressIntervalFor(
          base: Duration(seconds: base),
          paused: paused,
          backgrounded: bg,
        );

    test('foreground playing uses the base interval', () {
      expect(cadence(), const Duration(seconds: 10));
      expect(cadence(base: 60), const Duration(seconds: 60));
    });

    test('paused downshifts to 60 s', () {
      expect(cadence(paused: true), const Duration(seconds: 60));
    });

    test('backgrounded playback keeps reporting, throttled to 30 s', () {
      expect(cadence(bg: true), const Duration(seconds: 30));
      expect(cadence(bg: true, base: 60), const Duration(seconds: 60));
    });

    test('backgrounded and paused sends nothing', () {
      expect(cadence(paused: true, bg: true), isNull);
    });
  });

  test('progress keeps flowing while backgrounded and playing', () {
    fakeAsync((async) {
      final service = build();
      service.attachPositionProvider(() => const Duration(seconds: 5));
      service.reportPlaybackStart(_track('a'), sessionId: 'sa');
      async.flushMicrotasks();
      service.suspendForBackground();
      async.elapse(const Duration(seconds: 61));
      final progress =
          requests.where((r) => r.path.endsWith('/Progress')).length;
      expect(progress, 2); // at 30 s and 60 s

      service.notifyPaused(true);
      async.elapse(const Duration(minutes: 5));
      expect(requests.where((r) => r.path.endsWith('/Progress')).length,
          progress);
      service.dispose();
    });
  });

  test('late stop of previous track does not wipe the new session', () async {
    final service = build();
    final a = _track('a');
    final b = _track('b');

    await service.reportPlaybackStart(a, sessionId: 'sa');
    gates['/jf/Sessions/Playing/Stopped:a'] = Completer<void>();
    final stopA = service.reportPlaybackStopped(a, const Duration(seconds: 5));
    await service.reportPlaybackStart(b, sessionId: 'sb');
    gates['/jf/Sessions/Playing/Stopped:a']!.complete();
    await stopA;

    await service.reportPlaybackProgress(b, const Duration(seconds: 1), false);
    final progress = requests.where((r) => r.path.endsWith('/Progress')).toList();
    expect(progress, hasLength(1));
    expect(progress.single.body['PlaySessionId'], 'sb');

    final stops = requests.where((r) => r.path.endsWith('/Stopped')).toList();
    expect(stops.single.body['PlaySessionId'], 'sa');
    service.dispose();
  });

  test('start(new) before stop(previous) still stops the right session', () async {
    final service = build();
    final a = _track('a');
    final b = _track('b');

    await service.reportPlaybackStart(a, sessionId: 'sa');
    await service.reportPlaybackStart(b, sessionId: 'sb');
    await service.reportPlaybackStopped(a, const Duration(seconds: 3));

    final stops = requests.where((r) => r.path.endsWith('/Stopped')).toList();
    expect(stops, hasLength(1));
    expect(stops.single.body['ItemId'], 'a');
    expect(stops.single.body['PlaySessionId'], 'sa');

    // b is still the active session.
    await service.reportPlaybackProgress(b, Duration.zero, false);
    expect(requests.last.body['PlaySessionId'], 'sb');
    service.dispose();
  });

  test('duplicate start and duplicate stop are no-ops', () async {
    final service = build();
    final a = _track('a');
    await service.reportPlaybackStart(a);
    await service.reportPlaybackStart(a);
    await service.reportPlaybackStopped(a, Duration.zero);
    await service.reportPlaybackStopped(a, Duration.zero);
    expect(requests.where((r) => r.path.endsWith('/Playing')), hasLength(1));
    expect(requests.where((r) => r.path.endsWith('/Stopped')), hasLength(1));
    service.dispose();
  });

  test('progress for a non-active track is ignored', () async {
    final service = build();
    await service.reportPlaybackStart(_track('a'));
    await service.reportPlaybackProgress(_track('zzz'), Duration.zero, false);
    expect(requests.where((r) => r.path.endsWith('/Progress')), isEmpty);
    service.dispose();
  });

  test('offline events are queued, carried over and flushed', () async {
    final old = build();
    old.setEnabled(false);
    await old.reportPlaybackStart(_track('a'), sessionId: 'sa', playMethod: 'Transcode');
    await old.reportPlaybackStopped(_track('a'), const Duration(seconds: 2));
    expect(requests, isEmpty);

    final replacementRequests = <String>[];
    final replacement = PlaybackReportingService(
      serverUrl: 'https://host/jf',
      accessToken: 'tok2',
      deviceId: 'dev',
      userId: 'u',
      httpClient: MockClient((request) async {
        replacementRequests.add(
          '${request.url.path} ${jsonDecode(request.body)['PlayMethod']}',
        );
        return http.Response('', 204);
      }),
    );
    expect(replacement.isSameAccountAs(old), isTrue);
    replacement.adoptStateFrom(old);
    old.dispose();
    await replacement.flushPendingReports();
    // PlaybackStopInfo has no PlayMethod field, so stop bodies omit it.
    expect(replacementRequests, [
      '/jf/Sessions/Playing Transcode',
      '/jf/Sessions/Playing/Stopped null',
    ]);
    replacement.dispose();
  });

  test('retired service still sends the ending stop but nothing new', () async {
    final service = build();
    await service.reportPlaybackStart(_track('a'), sessionId: 'sa');
    service.retire();
    await service.reportPlaybackStopped(_track('a'), Duration.zero);
    await service.reportPlaybackStart(_track('b'));
    await service.reportPlaybackProgress(_track('b'), Duration.zero, false);
    expect(requests.map((r) => r.path), [
      '/jf/Sessions/Playing',
      '/jf/Sessions/Playing/Stopped',
    ]);
    expect(service.isRetired, isTrue);
    service.dispose();
  });

  test('disposed service makes no requests', () async {
    final service = build();
    service.dispose();
    await service.reportPlaybackStart(_track('a'));
    await service.reportPlaybackStopped(_track('a'), Duration.zero);
    expect(requests, isEmpty);
  });

  group('persisted offline queue', () {
    PlaybackReportingService withStore(
      _MemoryStore store,
      List<String> sent,
    ) =>
        PlaybackReportingService(
          serverUrl: 'https://host/jf',
          accessToken: 'tok',
          deviceId: 'dev',
          userId: 'u',
          pendingStore: store,
          httpClient: MockClient((request) async {
            sent.add(request.url.path);
            return http.Response('', 204);
          }),
        );

    test('events survive a restart and flush once', () async {
      final store = _MemoryStore();
      final sent = <String>[];
      final before = withStore(store, sent)..setEnabled(false);
      await before.reportPlaybackStart(_track('a'), sessionId: 'sa');
      await before.reportPlaybackStopped(_track('a'), Duration.zero);
      before.dispose(); // app killed

      final after = withStore(store, sent);
      await after.flushPendingReports();
      expect(sent, ['/jf/Sessions/Playing', '/jf/Sessions/Playing/Stopped']);
      expect(store.data.values.expand((e) => e), isEmpty);
      await after.flushPendingReports();
      expect(sent, hasLength(2));
      after.dispose();
    });

    test('queue is capped, dropping the oldest', () async {
      final store = _MemoryStore();
      final service = withStore(store, [])..setEnabled(false);
      for (var i = 0; i < PlaybackReportingService.maxPendingEvents + 10; i++) {
        await service.reportPlaybackStart(_track('t$i'), sessionId: 's$i');
      }
      final saved = store.data.values.single;
      expect(saved, hasLength(PlaybackReportingService.maxPendingEvents));
      expect(saved.first['sessionId'], 's10');
      service.dispose();
    });

    test('logout clears the persisted queue', () async {
      final store = _MemoryStore();
      final service = withStore(store, [])..setEnabled(false);
      await service.reportPlaybackStart(_track('a'), sessionId: 'sa');
      service.retire();
      await Future<void>.delayed(Duration.zero);
      expect(store.data.values.expand((e) => e), isEmpty);
      service.dispose();
    });
  });

  group('delivery failures keep reports queued', () {
    test('status classification', () {
      expect(PlaybackReportingService.outcomeForStatus(204), ReportOutcome.delivered);
      expect(PlaybackReportingService.outcomeForStatus(503), ReportOutcome.retryLater);
      expect(PlaybackReportingService.outcomeForStatus(401), ReportOutcome.retryLater);
      expect(PlaybackReportingService.outcomeForStatus(429), ReportOutcome.retryLater);
      expect(PlaybackReportingService.outcomeForStatus(400), ReportOutcome.drop);
    });

    test('flush stops on a transient failure and retains the rest', () async {
      final store = _MemoryStore();
      var failFrom = 1; // second request fails
      var calls = 0;
      final sent = <String>[];
      final service = PlaybackReportingService(
        serverUrl: 'https://host/jf',
        accessToken: 'tok',
        deviceId: 'dev',
        userId: 'u',
        pendingStore: store,
        httpClient: MockClient((request) async {
          final n = calls++;
          if (n >= failFrom) throw http.ClientException('network down');
          sent.add('${request.url.path} ${jsonDecode(request.body)['ItemId']}');
          return http.Response('', 204);
        }),
      )..setEnabled(false);
      await service.reportPlaybackStart(_track('a'), sessionId: 'sa');
      await service.reportPlaybackStopped(_track('a'), Duration.zero);
      await service.reportPlaybackStart(_track('b'), sessionId: 'sb');
      service.setEnabled(true);

      await service.flushPendingReports();
      expect(sent, ['/jf/Sessions/Playing a']);
      final kept = store.data.values.single;
      expect(kept.map((e) => '${e['type']} ${e['sessionId']}'),
          ['stop sa', 'start sb']);

      failFrom = 1 << 30; // server reachable again
      await service.flushPendingReports();
      expect(sent, [
        '/jf/Sessions/Playing a',
        '/jf/Sessions/Playing/Stopped a',
        '/jf/Sessions/Playing b',
      ]);
      expect(store.data.values.expand((e) => e), isEmpty);
      service.dispose();
    });

    test('permanent rejections are dropped instead of blocking the queue',
        () async {
      final store = _MemoryStore();
      final service = PlaybackReportingService(
        serverUrl: 'https://host/jf',
        accessToken: 'tok',
        deviceId: 'dev',
        userId: 'u',
        pendingStore: store,
        httpClient: MockClient((_) async => http.Response('', 400)),
      )..setEnabled(false);
      await service.reportPlaybackStart(_track('a'), sessionId: 'sa');
      service.setEnabled(true);
      await service.flushPendingReports();
      expect(store.data.values.expand((e) => e), isEmpty);
      service.dispose();
    });

    test('an online start/stop that fails is queued and replayed in order',
        () async {
      var down = true;
      final sent = <String>[];
      final service = PlaybackReportingService(
        serverUrl: 'https://host/jf',
        accessToken: 'tok',
        deviceId: 'dev',
        userId: 'u',
        httpClient: MockClient((request) async {
          if (down) return http.Response('', 503);
          sent.add(request.url.path);
          return http.Response('', 204);
        }),
      );
      await service.reportPlaybackStart(_track('a'), sessionId: 'sa');
      down = false;
      // The start is still queued, so the stop queues behind it and both
      // go out in order.
      await service.reportPlaybackStopped(_track('a'), Duration.zero);
      await service.flushPendingReports();
      expect(sent, ['/jf/Sessions/Playing', '/jf/Sessions/Playing/Stopped']);
      service.dispose();
    });

    test('a stop waits for its in-flight start, so the start never lands last',
        () async {
      final startGate = Completer<void>();
      var startFails = true;
      final sent = <String>[];
      final service = PlaybackReportingService(
        serverUrl: 'https://host/jf',
        accessToken: 'tok',
        deviceId: 'dev',
        userId: 'u',
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path == '/jf/Sessions/Playing' && startFails) {
            await startGate.future; // slow, then fails
            startFails = false;
            return http.Response('', 503);
          }
          sent.add(path);
          return http.Response('', 204);
        }),
      );
      final start = service.reportPlaybackStart(_track('a'), sessionId: 'sa');
      await Future<void>.delayed(Duration.zero);
      // Skip while the start is still in flight.
      final stop = service.reportPlaybackStopped(_track('a'), Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty); // the stop did not overtake the start
      startGate.complete();
      await start;
      await stop;
      await service.flushPendingReports();
      expect(sent, ['/jf/Sessions/Playing', '/jf/Sessions/Playing/Stopped']);
      service.dispose();
    });
  });
}
