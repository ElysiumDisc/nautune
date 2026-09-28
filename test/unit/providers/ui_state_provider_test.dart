import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_service.dart';
import 'package:nautune/models/playback_state.dart';
import 'package:nautune/providers/ui_state_provider.dart';
import 'package:nautune/services/playback_state_store.dart';

/// In-memory store: returns [stored] from load(), ignores saves.
class _FakeStore implements PlaybackStateStore {
  _FakeStore([this.stored]);
  final PlaybackState? stored;

  @override
  Future<PlaybackState?> load() async => stored;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  test('setCacheTtl reaches JellyfinService', () {
    final service = JellyfinService();
    final provider = UIStateProvider(
      playbackStateStore: _FakeStore(),
      jellyfinService: service,
    );
    provider.setCacheTtl(45);
    expect(provider.cacheTtlMinutes, 45);
    expect(service.cacheTtl, const Duration(minutes: 45));
    provider.setCacheTtl(0);
    expect(service.cacheTtl, const Duration(minutes: 1), reason: 'clamped');
  });

  test('initialize applies the persisted TTL to JellyfinService', () async {
    final service = JellyfinService();
    final provider = UIStateProvider(
      playbackStateStore: _FakeStore(PlaybackState(cacheTtlMinutes: 30)),
      jellyfinService: service,
    );
    await provider.initialize();
    expect(service.cacheTtl, const Duration(minutes: 30));
  });

  test('works without a service (backwards compatible)', () {
    final provider = UIStateProvider(playbackStateStore: _FakeStore());
    provider.setCacheTtl(10);
    expect(provider.cacheTtlMinutes, 10);
  });
}
