import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nautune/jellyfin/jellyfin_service.dart';
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
}) =>
    DownloadItem(
      track: JellyfinTrack(
        id: id,
        name: 'Track $id',
        album: 'Album',
        albumId: 'album1',
        artists: const ['Artist'],
        runTimeTicks: 1800000000,
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

  test('reloads per-track records and drops records whose file vanished',
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
    expect(service.getDownload('gone'), isNull); // file missing
    expect(service.completedBytes, 3);

    await service.flushPendingSave();
    expect(box.containsKey('t:gone'), isFalse);
    expect(box.containsKey('t:junk'), isFalse);
    expect(box.containsKey('t:a'), isTrue);

    // Removing the last owner deletes the file too.
    await service.deleteDownloadReference('a', 'album1');
    await service.flushPendingSave();
    expect(box.containsKey('t:a'), isFalse);
    expect(await File('${downloadsDir.path}/a_Track a.flac').exists(), isFalse);

    service.dispose();
  });
}
