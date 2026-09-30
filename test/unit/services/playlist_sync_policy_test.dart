import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/playlist_sync_queue.dart';

void main() {
  final queuedAt = DateTime.utc(2026, 9, 1, 12);
  final now = queuedAt.add(const Duration(days: 1));

  PendingActionFailureDecision decide({
    int attempts = 0,
    int? status,
    bool invalidPayload = false,
    DateTime? at,
  }) =>
      decidePendingActionFailure(
        attempts: attempts,
        queuedAt: queuedAt,
        now: at ?? now,
        httpStatus: status,
        invalidPayload: invalidPayload,
      );

  group('decidePendingActionFailure', () {
    test('network errors / timeouts are kept and never counted', () {
      final d = decide(attempts: 100);
      expect(d.drop, isFalse);
      expect(d.attempts, 100);
    });

    test('401 / 408 / 429 are kept and not counted', () {
      for (final status in [401, 408, 429]) {
        final d = decide(attempts: 7, status: status);
        expect(d.drop, isFalse, reason: '$status');
        expect(d.attempts, 7, reason: '$status');
      }
    });

    test('other 4xx and malformed payloads are dropped at once', () {
      expect(decide(status: 404).drop, isTrue);
      expect(decide(status: 400).drop, isTrue);
      expect(decide(invalidPayload: true).drop, isTrue);
    });

    test('5xx is counted and dropped after the limit', () {
      final first = decide(status: 500);
      expect(first.drop, isFalse);
      expect(first.attempts, 1);
      expect(
        decide(attempts: kMaxPendingActionServerErrors - 1, status: 503).drop,
        isTrue,
      );
    });

    test('actions that still fail after the max age are dropped', () {
      final old = queuedAt.add(kPendingActionMaxAge + const Duration(days: 1));
      expect(decide(at: old).drop, isTrue);
      expect(decide(at: queuedAt.add(const Duration(days: 89))).drop, isFalse);
    });
  });

  group('retriedCreateAlreadyApplied', () {
    bool applied({
      bool maybeApplied = true,
      List<({String name, DateTime? created})> server = const [],
    }) =>
        retriedCreateAlreadyApplied(
          maybeApplied: maybeApplied,
          name: 'Road trip',
          queuedAt: queuedAt,
          serverPlaylists: server,
        );

    test('a same-named playlist created after queueing counts as applied', () {
      expect(
        applied(server: [
          (name: 'Road trip', created: queuedAt.add(const Duration(minutes: 3))),
        ]),
        isTrue,
      );
    });

    test('never de-dups when no earlier attempt may have reached the server',
        () {
      expect(
        applied(maybeApplied: false, server: [
          (name: 'Road trip', created: queuedAt.add(const Duration(minutes: 3))),
        ]),
        isFalse,
      );
    });

    test('an older playlist or an unknown creation date is not a match', () {
      expect(
        applied(server: [
          (name: 'Road trip', created: queuedAt.subtract(const Duration(days: 30))),
          (name: 'Road trip', created: null),
          (name: 'Other', created: queuedAt.add(const Duration(minutes: 1))),
        ]),
        isFalse,
      );
    });
  });

  test('PendingPlaylistAction round-trips attempts and maybeApplied', () {
    final action = PendingPlaylistAction(
      type: 'create',
      payload: {'name': 'X'},
      timestamp: queuedAt,
    ).copyWith(attempts: 2, maybeApplied: true);
    final restored = PendingPlaylistAction.fromJson(action.toJson());
    expect(restored.id, action.id);
    expect(restored.attempts, 2);
    expect(restored.maybeApplied, isTrue);
    expect(
      PendingPlaylistAction.fromJson({
        'type': 'favorite',
        'payload': <String, dynamic>{},
        'timestamp': queuedAt.toIso8601String(),
      }).maybeApplied,
      isFalse,
    );
  });
}
