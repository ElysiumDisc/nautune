import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nautune/jellyfin/jellyfin_credentials.dart';
import 'package:nautune/jellyfin/jellyfin_service.dart';
import 'package:nautune/jellyfin/jellyfin_session.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/models/download_item.dart';
import 'package:nautune/services/download_service.dart';
import 'package:nautune/utils/download_status.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';

  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/documents';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

JellyfinTrack _track(String id, {String? albumId = 'album1'}) => JellyfinTrack(
      id: id,
      name: 'Track $id',
      album: 'Album',
      albumId: albumId,
      artists: const ['Artist A', 'Artist B'],
      artistIds: const ['ar-a', 'ar-b'],
      runTimeTicks: 1800000000,
      container: 'flac',
      serverUrl: 'http://jf.example',
      userId: 'user-1',
      indexNumber: 7,
      parentIndexNumber: 2,
      isFavorite: true,
      normalizationGain: -6.5,
      albumNormalizationGain: -5.25,
      genres: const ['Jazz'],
      tags: const ['chill'],
      providerIds: const {'MusicBrainzTrack': 'mbid'},
      primaryImageTag: 'tag1',
    );

JellyfinService _signedIn() => JellyfinService()
  ..restoreSession(JellyfinSession(
    serverUrl: 'http://jf.example',
    username: 'u',
    credentials:
        const JellyfinCredentials(accessToken: 'secret-token', userId: 'user-1'),
    deviceId: 'device',
  ));

Future<void> _waitFor(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory downloadsDir;
  late Box<dynamic> box;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('nautune_dl_resume_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    downloadsDir = Directory('${tmp.path}/support/downloads');
    await downloadsDir.create(recursive: true);
    await File('${downloadsDir.path}/.migrated_from_documents')
        .writeAsString('test');
    await Hive.initFlutter('nautune');
    box = await Hive.openBox<dynamic>('nautune_downloads');
  });

  setUp(() async => box.clear());

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('full track metadata survives a relaunch; old records are flagged',
      () async {
    await File('${downloadsDir.path}/m_Track m.flac').writeAsBytes([1, 2, 3]);
    await File('${downloadsDir.path}/old_Track old.flac').writeAsBytes([1]);
    final item = DownloadItem(
      track: _track('m'),
      localPath: 'm_Track m.flac',
      status: DownloadStatus.completed,
      queuedAt: DateTime(2026, 1, 1),
      completedAt: DateTime(2026, 1, 2),
      owners: {'album1'},
      fileSizeBytes: 3,
    );
    await box.put('t:m', item.toJson());
    // Written by an older version: no full metadata.
    final legacy = item.toJson()
      ..remove('trackMeta')
      ..remove('trackIndexNumber')
      ..['localPath'] = 'old_Track old.flac';
    await box.put('t:old', legacy);

    final service = DownloadService(jellyfinService: JellyfinService());
    await service.ready;

    final track = service.trackFor('m')!;
    expect(track.indexNumber, 7);
    expect(track.parentIndexNumber, 2);
    expect(track.isFavorite, isTrue);
    expect(track.normalizationGain, -6.5);
    expect(track.albumNormalizationGain, -5.25);
    expect(track.genres, ['Jazz']);
    expect(track.tags, ['chill']);
    expect(track.providerIds, {'MusicBrainzTrack': 'mbid'});
    expect(track.primaryImageTag, 'tag1');
    expect(service.getDownload('m')!.hasFullMetadata, isTrue);
    expect(service.getDownload('old')!.hasFullMetadata, isFalse);

    service.dispose();
  });

  test('mergeServerMetadata fills what old records lacked', () {
    final local = JellyfinTrack(
      id: 'x',
      name: 'Local',
      album: 'Album',
      artists: const ['A & 1 more'],
      runTimeTicks: 42,
    );
    final merged =
        DownloadService.mergeServerMetadata(local, _track('x'));
    expect(merged.indexNumber, 7);
    expect(merged.genres, ['Jazz']);
    expect(merged.artists, ['Artist A', 'Artist B']);
    expect(merged.runTimeTicks, 42); // probed from the file: kept
    expect(merged.name, 'Local');
  });

  test('a transfer cut off by the network resumes with a Range request',
      () async {
    final requests = <http.BaseRequest>[];
    final body = List<int>.generate(10, (i) => i);
    final client = MockClient.streaming((request, _) async {
      requests.add(request);
      if (!request.url.path.endsWith('/Download')) {
        return http.StreamedResponse(const Stream.empty(), 404);
      }
      final range = request.headers['Range'];
      if (range == null) {
        Stream<List<int>> cutOff() async* {
          yield body.sublist(0, 4);
          throw http.ClientException(
            'Connection reset',
            Uri.parse('http://jf.example/Items/r/Download?ApiKey=secret-token'),
          );
        }

        return http.StreamedResponse(cutOff(), 200,
            contentLength: 10,
            headers: {
              'content-type': 'audio/flac',
              'accept-ranges': 'bytes',
              'etag': '"v1"',
            });
      }
      expect(range, 'bytes=4-');
      expect(request.headers['If-Range'], '"v1"');
      return http.StreamedResponse(Stream.value(body.sublist(4)), 206,
          contentLength: 6,
          headers: {
            'content-type': 'audio/flac',
            'content-range': 'bytes 4-9/10',
          });
    });

    final service =
        DownloadService(jellyfinService: _signedIn(), httpClient: client);
    await service.ready;
    service.loadSettings();
    await service.downloadTracks([_track('r')], ownerId: 'album1');

    await _waitFor(() =>
        service.queuePause == DownloadQueuePause.waitingForNetwork);
    final failed = service.getDownload('r')!;
    expect(failed.status, DownloadStatus.queued);
    // The token in the failed URL is never stored.
    expect(failed.errorMessage, isNot(contains('secret-token')));
    expect(failed.errorMessage, contains('ApiKey=<redacted>'));

    service.retryDownload('r'); // skip the backoff
    await _waitFor(() => service.isDownloaded('r'));

    final done = service.getDownload('r')!;
    expect(done.status, DownloadStatus.completed);
    expect(await File(done.localPath).readAsBytes(), body);
    // One cut-off transfer, one resume (then artwork requests).
    expect(requests.where((r) => r.url.path.endsWith('/Download')), hasLength(2));
    // No temp file left behind.
    final leftovers = downloadsDir
        .listSync()
        .where((e) => e.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);

    service.dispose();
  });

  test('a resume the server answers in full starts over', () async {
    final body = List<int>.generate(10, (i) => 100 + i);
    var calls = 0;
    final client = MockClient.streaming((request, _) async {
      calls++;
      if (calls == 1) {
        Stream<List<int>> cutOff() async* {
          yield body.sublist(0, 3);
          throw http.ClientException('reset');
        }

        return http.StreamedResponse(cutOff(), 200,
            contentLength: 10,
            headers: {
              'content-type': 'audio/flac',
              'accept-ranges': 'bytes',
              'etag': '"v1"',
            });
      }
      // The file changed: If-Range doesn't match, the whole file comes back.
      return http.StreamedResponse(Stream.value(body), 200,
          contentLength: 10, headers: {'content-type': 'audio/flac'});
    });

    final service =
        DownloadService(jellyfinService: _signedIn(), httpClient: client);
    await service.ready;
    service.loadSettings();
    await service.downloadTracks([_track('f')]);
    await _waitFor(() =>
        service.queuePause == DownloadQueuePause.waitingForNetwork);
    service.retryDownload('f');
    await _waitFor(() => service.isDownloaded('f'));

    expect(await File(service.getDownload('f')!.localPath).readAsBytes(), body);
    service.dispose();
  });

  test('offline mode suspends the queue until resumed', () async {
    var calls = 0;
    final client = MockClient.streaming((request, _) async {
      calls++;
      return http.StreamedResponse(Stream.value([1, 2, 3]), 200,
          contentLength: 3, headers: {'content-type': 'audio/flac'});
    });
    final service =
        DownloadService(jellyfinService: _signedIn(), httpClient: client);
    await service.ready;
    service.loadSettings();
    service.setSuspended(true);

    await service.downloadTracks([_track('s')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, 0);
    expect(service.queuePause, DownloadQueuePause.offline);

    service.setSuspended(false);
    await _waitFor(() => service.isDownloaded('s'));
    expect(service.isDownloaded('s'), isTrue);
    expect(service.queuePause, DownloadQueuePause.none);
    service.dispose();
  });

  test('removing an album keeps tracks a playlist still owns', () async {
    for (final id in ['p', 'q']) {
      await File('${downloadsDir.path}/${id}_Track $id.flac')
          .writeAsBytes([1, 2, 3]);
    }
    DownloadItem item(String id, Set<String> owners) => DownloadItem(
          track: _track(id),
          localPath: '${id}_Track $id.flac',
          status: DownloadStatus.completed,
          queuedAt: DateTime(2026, 1, 1),
          completedAt: DateTime(2026, 1, 2),
          owners: owners,
          fileSizeBytes: 3,
        );
    await box.put('t:p', item('p', {'album1'}).toJson());
    await box.put('t:q', item('q', {'album1', 'playlist1'}).toJson());

    final service = DownloadService(jellyfinService: JellyfinService());
    await service.ready;
    final result = await service.releaseAlbumDownloads('album1');
    expect(result.removed, 1);
    expect(result.kept, 1);
    expect(service.getDownload('p'), isNull);
    expect(service.getDownload('q')!.owners, {'playlist1'});
    service.dispose();
  });

  test('library lists show only the signed-in account', () async {
    for (final id in ['mine', 'theirs']) {
      await File('${downloadsDir.path}/${id}_Track $id.flac')
          .writeAsBytes([1, 2, 3]);
    }
    DownloadItem item(String id, String userId) => DownloadItem(
          track: _track(id).copyWith(userId: userId),
          localPath: '${id}_Track $id.flac',
          status: DownloadStatus.completed,
          queuedAt: DateTime(2026, 1, 1),
          completedAt: DateTime(2026, 1, 2),
          owners: const {},
          fileSizeBytes: 3,
        );
    await box.put('t:mine', item('mine', 'user-1').toJson());
    await box.put('t:theirs', item('theirs', 'user-2').toJson());

    final service = DownloadService(jellyfinService: _signedIn());
    await service.ready;
    expect([for (final d in service.completedDownloads) d.track.id], ['mine']);
    expect(service.allCompletedDownloads, hasLength(2));
    expect(service.completedCount, 2);
    service.dispose();
  });
}
