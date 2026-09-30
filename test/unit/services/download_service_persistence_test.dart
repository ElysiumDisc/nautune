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

Map<String, dynamic> _record({
  required String id,
  required String localPath,
  required String status,
  List<String> owners = const [],
  String? serverUrl,
  String? userId,
}) =>
    DownloadItem(
      track: JellyfinTrack(
        id: id,
        name: 'Track $id',
        album: 'Album',
        albumId: 'album1',
        artists: const ['Artist'],
        runTimeTicks: 1800000000,
        container: 'flac',
        serverUrl: serverUrl,
        userId: userId,
      ),
      localPath: localPath,
      status: DownloadStatus.values.byName(status),
      queuedAt: DateTime(2026, 1, 1),
      completedAt: status == 'completed' ? DateTime(2026, 1, 2) : null,
      owners: owners.toSet(),
      fileSizeBytes: status == 'completed' ? 3 : null,
    ).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory downloadsDir;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('nautune_dl_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    downloadsDir = Directory('${tmp.path}/support/downloads');
    await downloadsDir.create(recursive: true);
    // Mark the Documents -> Support migration as done.
    await File('${downloadsDir.path}/.migrated_from_documents')
        .writeAsString('test');
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('migrates the legacy single-map record to per-track records', () async {
    await Hive.initFlutter('nautune');
    final box = await Hive.openBox<dynamic>('nautune_downloads');
    await File('${downloadsDir.path}/a_Track a.flac').writeAsBytes([1, 2, 3]);
    await box.put('downloads', {
      // Legacy absolute path from another app container.
      'a': _record(
        id: 'a',
        localPath:
            '/var/mobile/Containers/Data/Application/OLD/Documents/downloads/a_Track a.flac',
        status: 'completed',
        owners: ['album1'],
      ),
      // Killed mid-download: must come back queued.
      'b': _record(id: 'b', localPath: 'b_Track b.flac', status: 'downloading'),
    });

    final service = DownloadService(jellyfinService: JellyfinService());
    await service.ready;

    expect(service.isDownloaded('a'), isTrue);
    expect(service.getDownload('a')!.localPath,
        '${downloadsDir.absolute.path}/a_Track a.flac');
    expect(service.getDownload('b')!.status, DownloadStatus.queued);

    await service.flushPendingSave();
    expect(box.containsKey('downloads'), isFalse);
    expect(box.containsKey('t:a'), isTrue);
    expect(box.containsKey('t:b'), isTrue);
    // Stored relative to the downloads root.
    expect((box.get('t:a') as Map)['localPath'], 'a_Track a.flac');

    // Only changed records are rewritten: deleting one removes its key and
    // leaves the other untouched.
    await service.deleteDownload('b');
    await service.flushPendingSave();
    expect(box.containsKey('t:b'), isFalse);
    expect(box.containsKey('t:a'), isTrue);

    service.dispose();
  });

  test('reloads per-track records; a vanished file is marked missing',
      () async {
    final box = Hive.box<dynamic>('nautune_downloads');
    await box.put(
      't:gone',
      _record(id: 'gone', localPath: 'gone_Track gone.flac', status: 'completed'),
    );
    await box.put('t:junk', 'not a map');

    final service = DownloadService(jellyfinService: JellyfinService());
    await service.ready;

    expect(service.isDownloaded('a'), isTrue); // from the previous test
    // File missing (e.g. after a device restore): kept, failed, retryable.
    final gone = service.getDownload('gone')!;
    expect(gone.status, DownloadStatus.failed);
    expect(gone.errorKind, DownloadErrorKind.missing);
    expect(service.completedBytes, 3);

    await service.flushPendingSave();
    expect((box.get('t:gone') as Map)['status'], 'failed');
    expect(box.containsKey('t:junk'), isFalse);
    expect(box.containsKey('t:a'), isTrue);

    // Removing the last owner deletes the file too.
    await service.deleteDownloadReference('a', 'album1');
    await service.flushPendingSave();
    expect(box.containsKey('t:a'), isFalse);
    expect(await File('${downloadsDir.path}/a_Track a.flac').exists(), isFalse);

    service.dispose();
  });

  test('downloads of another account stay queued; non-audio 200 fails',
      () async {
    final box = Hive.box<dynamic>('nautune_downloads');
    await box.clear();
    await box.put(
      't:foreign',
      _record(
        id: 'foreign',
        localPath: 'foreign_Track foreign.flac',
        status: 'queued',
        serverUrl: 'http://a.example',
        userId: 'user-a',
      ),
    );
    // Written by an older version: no account stored.
    await box.put(
      't:mine',
      _record(id: 'mine', localPath: 'mine_Track mine.flac', status: 'queued'),
    );

    final jellyfin = JellyfinService()
      ..restoreSession(JellyfinSession(
        serverUrl: 'http://b.example',
        username: 'b',
        credentials:
            const JellyfinCredentials(accessToken: 'token-b', userId: 'user-b'),
        deviceId: 'device',
      ));
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      // A reverse-proxy login page instead of audio.
      return http.Response('<html>login</html>', 200,
          headers: {'content-type': 'text/html'});
    });
    final service = DownloadService(jellyfinService: jellyfin, httpClient: client);
    await service.ready;
    // The queue waits for the user's download settings.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requested, isEmpty);
    service.loadSettings();

    for (var i = 0; i < 100 && !service.getDownload('mine')!.isFailed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final mine = service.getDownload('mine')!;
    expect(mine.status, DownloadStatus.failed);
    expect(mine.errorKind, DownloadErrorKind.server);
    expect(await File('${downloadsDir.path}/mine_Track mine.flac').exists(),
        isFalse);
    expect(service.getDownload('foreign')!.status, DownloadStatus.queued);
    expect(requested.any((u) => u.path.contains('foreign')), isFalse);
    expect(requested.every((u) => u.host == 'b.example'), isTrue);

    await service.flushPendingSave();
    final foreignRecord = box.get('t:foreign') as Map;
    expect(foreignRecord['serverUrl'], 'http://a.example');
    expect(foreignRecord['userId'], 'user-a');
    // The legacy record now belongs to the signed-in account; the access
    // token itself is never persisted.
    final mineRecord = box.get('t:mine') as Map;
    expect(mineRecord['serverUrl'], 'http://b.example');
    expect(mineRecord['userId'], 'user-b');
    expect(mineRecord.containsKey('token'), isFalse);

    service.dispose();
  });

  test('releasing a collection keeps tracks another collection owns',
      () async {
    final box = Hive.box<dynamic>('nautune_downloads');
    await box.clear();
    final solo = File('${downloadsDir.path}/solo_Track solo.flac');
    final shared = File('${downloadsDir.path}/shared_Track shared.flac');
    await solo.writeAsBytes([1, 2, 3]);
    await shared.writeAsBytes([1, 2, 3]);
    await box.put(
      't:solo',
      _record(
        id: 'solo',
        localPath: 'solo_Track solo.flac',
        status: 'completed',
        owners: ['playlist1'],
      ),
    );
    await box.put(
      't:shared',
      _record(
        id: 'shared',
        localPath: 'shared_Track shared.flac',
        status: 'completed',
        owners: ['playlist1', 'album1'],
      ),
    );

    final service = DownloadService(jellyfinService: JellyfinService());
    await service.ready;

    final result = await service.releaseDownloads(['solo', 'shared'], 'playlist1');
    expect(result.removed, 1);
    expect(result.kept, 1);
    expect(service.getDownload('solo'), isNull);
    expect(await solo.exists(), isFalse);
    expect(service.getDownload('shared')!.owners, {'album1'});
    expect(await shared.exists(), isTrue);

    await service.flushPendingSave();
    expect(box.containsKey('t:solo'), isFalse);
    expect((box.get('t:shared') as Map)['owners'], ['album1']);

    service.dispose();
  });
}
