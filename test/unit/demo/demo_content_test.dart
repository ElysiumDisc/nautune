import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/demo/demo_content.dart';
import 'package:nautune/jellyfin/jellyfin_playlist.dart';

void main() {
  test('demo playlists can be replaced more than once', () {
    // DemoModeProvider replaces the list on every create / rename / delete /
    // add; a `late final` field threw LateInitializationError here.
    final content = DemoContent();
    final created = JellyfinPlaylist(id: 'demo-playlist-2', name: 'New', trackCount: 0);
    content.playlists = [...content.playlists, created];
    expect(content.playlists.map((p) => p.id), contains('demo-playlist-2'));
    content.playlists =
        content.playlists.where((p) => p.id != 'demo-playlist-2').toList();
    expect(content.playlists.map((p) => p.id), isNot(contains('demo-playlist-2')));
  });
}
