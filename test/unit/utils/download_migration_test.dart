import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/download_migration.dart';

void main() {
  late Directory sandbox;
  late Directory legacy;
  late Directory target;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('nautune_migration_');
    legacy = Directory('${sandbox.path}/Documents/downloads');
    target = Directory('${sandbox.path}/Library/Application Support/downloads');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<void> seedLegacy() async {
    await Directory('${legacy.path}/artwork').create(recursive: true);
    await Directory('${legacy.path}/artists').create(recursive: true);
    await File('${legacy.path}/t1_Song.flac').writeAsString('audio1');
    await File('${legacy.path}/t2_Other.mp3').writeAsString('audio2');
    await File('${legacy.path}/artwork/al1.jpg').writeAsString('art');
    await File('${legacy.path}/artists/ar1.jpg').writeAsString('artist');
  }

  File marker() => File('${target.path}/${DownloadMigration.markerName}');

  test('no legacy directory: creates target and marker', () async {
    expect(await DownloadMigration.migrate(from: legacy, to: target), isTrue);
    expect(await target.exists(), isTrue);
    expect(await marker().exists(), isTrue);
  });

  test('moves the whole tree when the target does not exist', () async {
    await seedLegacy();
    expect(await DownloadMigration.migrate(from: legacy, to: target), isTrue);
    expect(await legacy.exists(), isFalse);
    expect(await File('${target.path}/t1_Song.flac').readAsString(), 'audio1');
    expect(await File('${target.path}/artwork/al1.jpg').readAsString(), 'art');
    expect(await File('${target.path}/artists/ar1.jpg').readAsString(), 'artist');
    expect(await marker().exists(), isTrue);
  });

  test('merges per-file when the target already exists (interrupted run)', () async {
    await seedLegacy();
    // Simulate a previous interrupted run: one file already moved, the
    // source copy not yet deleted, plus a stale staging file and partial.
    await Directory('${target.path}/artwork').create(recursive: true);
    await File('${target.path}/t1_Song.flac').writeAsString('audio1');
    await File('${target.path}/t2_Other.mp3.migrating').writeAsString('au');
    await File('${legacy.path}/t3_Partial.flac.tmp').writeAsString('x');

    expect(await DownloadMigration.migrate(from: legacy, to: target), isTrue);
    expect(await legacy.exists(), isFalse);
    expect(await File('${target.path}/t1_Song.flac').readAsString(), 'audio1');
    expect(await File('${target.path}/t2_Other.mp3').readAsString(), 'audio2');
    expect(await File('${target.path}/artwork/al1.jpg').exists(), isTrue);
    expect(await File('${target.path}/t2_Other.mp3.migrating').exists(), isFalse);
    expect(await File('${target.path}/t3_Partial.flac.tmp').exists(), isFalse);
    expect(await marker().exists(), isTrue);
  });

  test('is idempotent: second run is a no-op once the marker exists', () async {
    await seedLegacy();
    expect(await DownloadMigration.migrate(from: legacy, to: target), isTrue);
    // A new legacy folder appearing later is not touched after completion.
    await legacy.create(recursive: true);
    await File('${legacy.path}/late.flac').writeAsString('late');
    expect(await DownloadMigration.migrate(from: legacy, to: target), isTrue);
    expect(await File('${legacy.path}/late.flac').exists(), isTrue);
    expect(await File('${target.path}/late.flac').exists(), isFalse);
  });

  test('same source and target is a no-op', () async {
    await seedLegacy();
    expect(await DownloadMigration.migrate(from: legacy, to: legacy), isTrue);
    expect(await File('${legacy.path}/t1_Song.flac').exists(), isTrue);
  });
}
