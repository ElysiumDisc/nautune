import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/models/download_item.dart';
import 'package:nautune/utils/download_status.dart';

DownloadItem _item(
  String id,
  DownloadStatus status, {
  double progress = 0,
}) =>
    DownloadItem(
      track: JellyfinTrack(id: id, name: id, album: null, artists: const ['A']),
      localPath: '/x/$id.flac',
      status: status,
      progress: progress,
      queuedAt: DateTime(2026, 1, 1),
      owners: {},
    );

void main() {
  group('CollectionDownloadSummary', () {
    test('empty collection is none', () {
      final s = CollectionDownloadSummary.fromItems(const []);
      expect(s.state, CollectionDownloadState.none);
      expect(s.progress, 0);
    });

    test('nothing downloaded is none', () {
      final s = CollectionDownloadSummary.fromItems([null, null]);
      expect(s.state, CollectionDownloadState.none);
      expect(s.remaining, 2);
    });

    test('all completed is complete', () {
      final s = CollectionDownloadSummary.fromItems([
        _item('a', DownloadStatus.completed),
        _item('b', DownloadStatus.completed),
      ]);
      expect(s.state, CollectionDownloadState.complete);
      expect(s.progress, 1.0);
    });

    test('some completed, rest untouched is partial', () {
      final s = CollectionDownloadSummary.fromItems([
        _item('a', DownloadStatus.completed),
        null,
      ]);
      expect(s.state, CollectionDownloadState.partial);
      expect(s.remaining, 1);
    });

    test('anything queued or downloading wins', () {
      final s = CollectionDownloadSummary.fromItems([
        _item('a', DownloadStatus.completed),
        _item('b', DownloadStatus.downloading, progress: 0.5),
        _item('c', DownloadStatus.queued),
        _item('d', DownloadStatus.failed),
      ]);
      expect(s.state, CollectionDownloadState.downloading);
      expect(s.active, 2);
      expect(s.failed, 1);
      expect(s.progress, closeTo((1 + 0.5) / 4, 1e-9));
      expect(s.remaining, 1); // the failed one
    });

    test('failures with nothing in flight is failed', () {
      final s = CollectionDownloadSummary.fromItems([
        _item('a', DownloadStatus.completed),
        _item('b', DownloadStatus.failed),
      ]);
      expect(s.state, CollectionDownloadState.failed);
    });

    test('indeterminate progress (-1) does not go negative', () {
      final s = CollectionDownloadSummary.fromItems([
        _item('a', DownloadStatus.downloading, progress: -1),
      ]);
      expect(s.progress, 0);
    });
  });

  group('networkRetryDelay', () {
    test('doubles from 5s and caps at 2 minutes', () {
      expect(networkRetryDelay(1), const Duration(seconds: 5));
      expect(networkRetryDelay(2), const Duration(seconds: 10));
      expect(networkRetryDelay(3), const Duration(seconds: 20));
      expect(networkRetryDelay(5), const Duration(seconds: 80));
      expect(networkRetryDelay(6), const Duration(seconds: 120));
      expect(networkRetryDelay(50), const Duration(seconds: 120));
      expect(networkRetryDelay(0), const Duration(seconds: 5));
    });
  });

  group('messages', () {
    test('every pause but none has an explanation', () {
      for (final pause in DownloadQueuePause.values) {
        final text = describeQueuePause(pause);
        if (pause == DownloadQueuePause.none) {
          expect(text, isNull);
        } else {
          expect(text, isNotEmpty);
        }
      }
    });

    test('error kinds map to short reasons', () {
      expect(describeDownloadError(DownloadErrorKind.storageFull),
          'Not enough storage');
      expect(describeDownloadError(null), 'Download failed');
    });

    test('formatDownloadBytes', () {
      expect(formatDownloadBytes(512), '512 B');
      expect(formatDownloadBytes(1536), '1.5 KB');
      expect(formatDownloadBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatDownloadBytes(3 * 1024 * 1024 * 1024), '3.00 GB');
    });
  });
}
