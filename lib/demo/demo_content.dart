import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';

int _ticksFromSeconds(int seconds) =>
    Duration(seconds: seconds).inMicroseconds * 10;

/// Static data that powers the on-device demo flow.
class DemoContent {
  DemoContent() {
    final onlineAlbumId = 'demo-online-album';
    final offlineAlbumId = 'demo-offline-album';

    final onlineTrack = JellyfinTrack(
      id: onlineTrackId,
      name: 'Ocean Vibes',
      album: 'Open Waters - Live at Sea',
      artists: const ['Pixabay · Ocean Vibes'],
      albumId: onlineAlbumId,
      runTimeTicks: _ticksFromSeconds(254),
      isFavorite: false,
      assetPathOverride: 'assets/demo/demo_online_track.mp3',
    );

    final offlineTrack = JellyfinTrack(
      id: offlineTrackId,
      name: 'Sirens and Silence',
      album: 'Harbor Sessions',
      artists: const ['Pixabay · Sirens and Silence'],
      albumId: offlineAlbumId,
      runTimeTicks: _ticksFromSeconds(192),
      isFavorite: true,
      assetPathOverride: 'assets/demo/demo_offline_track.mp3',
    );

    tracks = {
      onlineTrack.id: onlineTrack,
      offlineTrack.id: offlineTrack,
    };

    library = JellyfinLibrary(
      id: 'demo-library',
      name: 'Nautune Showcase Library',
      collectionType: 'music',
    );

    albums = [
      JellyfinAlbum(
        id: onlineAlbumId,
        name: 'Open Waters - Live at Sea',
        artists: const ['Komiku'],
        artistIds: const ['demo-artist-online'],
        productionYear: 2020,
        genres: const ['Indie Electronic', 'Soundtrack'],
      ),
      JellyfinAlbum(
        id: offlineAlbumId,
        name: 'Harbor Sessions',
        artists: const ['Nautune House Band'],
        artistIds: const ['demo-artist-offline'],
        productionYear: 2024,
        genres: const ['Ambient', 'Electronic'],
      ),
    ];

    artists = [
      JellyfinArtist(
        id: 'demo-artist-online',
        name: 'Komiku',
        overview:
            'Open source composer whose catalogue lives on Free Music Archive.',
        genres: const ['Indie Electronic'],
        albumCount: 1,
        songCount: 1,
      ),
      JellyfinArtist(
        id: 'demo-artist-offline',
        name: 'Nautune House Band',
        overview: 'An in-house collective used for showcasing offline playback.',
        genres: const ['Ambient'],
        albumCount: 1,
        songCount: 1,
      ),
    ];

    playlists = [
      JellyfinPlaylist(
        id: 'demo-playlist-golden-hour',
        name: 'Golden Hour Cruise',
        trackCount: 2,
      ),
    ];

    genres = const [
      JellyfinGenre(
        id: 'demo-genre-wave',
        name: 'Wave Breaker',
        albumCount: 1,
        trackCount: 1,
      ),
      JellyfinGenre(
        id: 'demo-genre-ambient',
        name: 'Ambient',
        albumCount: 1,
        trackCount: 1,
      ),
    ];

    albumTrackIds = {
      onlineAlbumId: [onlineTrackId],
      offlineAlbumId: [offlineTrackId],
    };

    playlistTrackIds = {
      'demo-playlist-golden-hour': [onlineTrackId, offlineTrackId],
    };

    recentTrackIds = [onlineTrackId];
    favoriteTrackIds = [offlineTrackId];
  }

  final String onlineTrackId = 'demo-track-online';
  final String offlineTrackId = 'demo-track-offline';

  late final JellyfinLibrary library;
  late final List<JellyfinAlbum> albums;
  late final List<JellyfinArtist> artists;
  late final List<JellyfinPlaylist> playlists;
  late final List<JellyfinGenre> genres;
  late final Map<String, JellyfinTrack> tracks;
  late final Map<String, List<String>> albumTrackIds;
  late final Map<String, List<String>> playlistTrackIds;
  late final List<String> recentTrackIds;
  late final List<String> favoriteTrackIds;
}
