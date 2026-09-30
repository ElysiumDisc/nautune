import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/models/playback_state.dart';
import 'package:nautune/services/playback_state_store.dart';

/// Map-backed store backend that records every write.
class _MemoryBackend implements PlaybackStateBackend {
  _MemoryBackend([Map<String, Object?>? initial]) : data = {...?initial};

  final Map<String, Object?> data;
  final List<Set<String>> writes = [];

  @override
  Future<Object?> read(String key) async => data[key];

  @override
  Future<void> write(Map<String, Object?> entries) async {
    writes.add(entries.keys.toSet());
    data.addAll(entries);
  }
}

/// Backend whose first [failures] reads throw (e.g. the box failed to open).
class _FlakyBackend extends _MemoryBackend {
  _FlakyBackend(super.initial, {required this.failures});

  int failures;

  @override
  Future<Object?> read(String key) async {
    if (failures > 0) {
      failures--;
      throw StateError('box unavailable');
    }
    return super.read(key);
  }
}

JellyfinTrack _track(String id) =>
    JellyfinTrack(id: id, name: 'Track $id', album: 'Album', artists: const ['Artist']);

void main() {
  test('many saves are coalesced into one write', () async {
    final backend = _MemoryBackend();
    final store = PlaybackStateStore.withBackend(
      backend,
      writeDelay: const Duration(milliseconds: 20),
    );
    for (var i = 0; i < 50; i++) {
      await store.savePlaybackSnapshot(volume: i / 50);
    }
    expect(backend.writes, isEmpty, reason: 'nothing is written per call');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(backend.writes, hasLength(1));
    expect((await store.load())!.volume, closeTo(49 / 50, 1e-9));
  });

  test('the queue is written under its own key, only when it changed', () async {
    final backend = _MemoryBackend();
    final store = PlaybackStateStore.withBackend(backend);
    await store.savePlaybackSnapshot(
      queue: [_track('a'), _track('b')],
      currentQueueIndex: 1,
    );
    await store.flush();
    expect(backend.writes.last, containsAll(<String>['state', 'queue']));
    final stateJson = backend.data['state']! as Map;
    expect(stateJson.containsKey('queueSnapshot'), isFalse);

    await store.saveUiState(showVolumeBar: false);
    await store.flush();
    expect(backend.writes.last, {'state'}, reason: 'a setting does not rewrite the queue');

    // A fresh store (next launch) reads both keys back.
    final reloaded = await PlaybackStateStore.withBackend(_MemoryBackend(backend.data)).load();
    expect(reloaded!.queueIds, ['a', 'b']);
    expect(reloaded.toQueueTracks().map((t) => t.id), ['a', 'b']);
    expect(reloaded.currentQueueIndex, 1);
    expect(reloaded.showVolumeBar, isFalse);
  });

  test('state saved by older versions (queue inside the state) keeps its queue '
      'and is migrated on the next write', () async {
    final legacy = PlaybackState(
      queueIds: const ['x', 'y'],
      queueSnapshot: [_track('x').toStorageJson(), _track('y').toStorageJson()],
      currentQueueIndex: 1,
      themePaletteId: 'custom_palette',
    ).toJson();
    final backend = _MemoryBackend({'state': legacy});
    final store = PlaybackStateStore.withBackend(backend);

    final loaded = await store.load();
    expect(loaded!.queueIds, ['x', 'y']);
    expect(loaded.themePaletteId, 'custom_palette');

    await store.savePlaybackSnapshot(position: const Duration(seconds: 3));
    await store.flush();
    expect(backend.data.containsKey('queue'), isTrue);

    final reloaded = await PlaybackStateStore.withBackend(_MemoryBackend(backend.data)).load();
    expect(reloaded!.queueIds, ['x', 'y']);
    expect(reloaded.positionMs, 3000);
  });

  test('clearPlaybackData clears the queue now and keeps settings, incl. offline mode',
      () async {
    final backend = _MemoryBackend();
    final store = PlaybackStateStore.withBackend(backend);
    await store.saveUiState(isOfflineMode: true, crossfadeEnabled: true);
    await store.savePlaybackSnapshot(queue: [_track('a')], currentTrack: _track('a'));
    await store.clearPlaybackData();

    // Written immediately (no delay needed).
    final reloaded = await PlaybackStateStore.withBackend(_MemoryBackend(backend.data)).load();
    expect(reloaded!.queueIds, isEmpty);
    expect(reloaded.queueSnapshot, isEmpty);
    expect(reloaded.currentTrackId, isNull);
    expect(reloaded.isOfflineMode, isTrue);
    expect(reloaded.crossfadeEnabled, isTrue);
  });

  test('nothing stored loads as null', () async {
    expect(await PlaybackStateStore.withBackend(_MemoryBackend()).load(), isNull);
  });

  test('a failed read writes nothing over the stored state; changes made '
      'meanwhile are applied on top of it once a read succeeds', () async {
    final stored = PlaybackState(
      themePaletteId: 'custom_palette',
      crossfadeEnabled: true,
      queueIds: const ['x'],
      queueSnapshot: [_track('x').toStorageJson()],
    ).toJson();
    final backend = _FlakyBackend({'state': stored}, failures: 2);
    final store = PlaybackStateStore.withBackend(
      backend,
      writeDelay: const Duration(milliseconds: 10),
    );

    // The first two reads fail (the save's and the flush's).
    await store.saveUiState(showVolumeBar: false);
    await store.flush();
    expect(backend.writes, isEmpty, reason: 'defaults must not replace the stored state');

    // The read is retried (here by the next access) and succeeds.
    final loaded = await store.load();
    expect(loaded!.themePaletteId, 'custom_palette', reason: 'stored settings kept');
    expect(loaded.crossfadeEnabled, isTrue);
    expect(loaded.queueIds, ['x']);
    expect(loaded.showVolumeBar, isFalse, reason: 'the change made meanwhile is kept');

    await store.flush();
    final reloaded = await PlaybackStateStore.withBackend(_MemoryBackend(backend.data)).load();
    expect(reloaded!.themePaletteId, 'custom_palette');
    expect(reloaded.showVolumeBar, isFalse);
    expect(reloaded.queueIds, ['x']);
  });

  test('a failed read is retried by itself when changes are waiting', () async {
    final backend = _FlakyBackend(
      {'state': PlaybackState(themePaletteId: 'custom_palette').toJson()},
      failures: 1,
    );
    final store = PlaybackStateStore.withBackend(
      backend,
      writeDelay: const Duration(milliseconds: 10),
    );
    await store.savePlaybackSnapshot(volume: 0.25);
    expect(backend.writes, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(backend.writes, isNotEmpty);
    final reloaded = await PlaybackStateStore.withBackend(_MemoryBackend(backend.data)).load();
    expect(reloaded!.themePaletteId, 'custom_palette');
    expect(reloaded.volume, 0.25);
  });
}
