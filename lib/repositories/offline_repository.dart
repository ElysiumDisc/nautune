import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/download_service.dart';
import 'music_repository.dart';

/// Offline implementation of MusicRepository.
///
/// Queries downloaded content from local Hive database.
/// Used when the app is in offline mode (no network connectivity).
///
/// Returns only tracks/albums/artists that have been downloaded.
/// Builds synthetic objects when necessary (e.g., albums from tracks).
class OfflineRepository implements MusicRepository {
  OfflineRepository({required DownloadService downloadService})
      : _downloadService = downloadService;

  final DownloadService _downloadService;

  @override
  Future<List<JellyfinLibrary>> getLibraries() async {
    // In offline mode, return a single synthetic "Downloads" library
    return [
      JellyfinLibrary(
        id: 'offline_downloads',
        name: 'Downloads',
        collectionType: 'music',
      ),
    ];
  }

  @override
  Future<List<JellyfinAlbum>> getAlbums({
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
    SortOption sortBy = SortOption.name,
    SortOrder sortOrder = SortOrder.ascending,
  }) async {
    final downloads = _downloadService.completedDownloads;
    final albums = <String, JellyfinAlbum>{};

    // Group tracks by album
    for (final download in downloads) {
      final track = download.track;
      final albumId = track.albumId ?? 'unknown';
      final albumName = track.album ?? 'Unknown Album';

      if (!albums.containsKey(albumId)) {
        albums[albumId] = JellyfinAlbum(
          id: albumId,
          name: albumName,
          artists: [track.displayArtist],
          primaryImageTag: track.albumPrimaryImageTag,
        );
      }
    }

    final albumList = albums.values.toList();
    
    // Sort based on options (offline only supports name sorting reliably)
    albumList.sort((a, b) {
      final comparison = a.name.compareTo(b.name);
      return sortOrder == SortOrder.ascending ? comparison : -comparison;
    });

    // Apply pagination
    final end = (startIndex + limit).clamp(0, albumList.length);
    return albumList.sublist(startIndex.clamp(0, albumList.length), end);
  }

  @override
  Future<List<JellyfinArtist>> getArtists({
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
    SortOption sortBy = SortOption.name,
    SortOrder sortOrder = SortOrder.ascending,
  }) async {
    final downloads = _downloadService.completedDownloads;
    final artists = <String, JellyfinArtist>{};

    // Group tracks by artist
    for (final download in downloads) {
      final track = download.track;
      final artistName = track.displayArtist;
      final artistId = track.artists.isNotEmpty ? track.artists.first : artistName;

      if (!artists.containsKey(artistId)) {
        artists[artistId] = JellyfinArtist(
          id: artistId,
          name: artistName,
          primaryImageTag: null, // Not available from track metadata
        );
      }
    }

    final artistList = artists.values.toList();
    
    // Sort based on options (offline only supports name sorting reliably)
    artistList.sort((a, b) {
      final comparison = a.name.compareTo(b.name);
      return sortOrder == SortOrder.ascending ? comparison : -comparison;
    });

    // Apply pagination
    final end = (startIndex + limit).clamp(0, artistList.length);
    return artistList.sublist(startIndex.clamp(0, artistList.length), end);
  }

  @override
  Future<List<JellyfinGenre>> getGenres({required String libraryId}) async {
    // Genres not available in offline mode
    return [];
  }

  @override
  Future<List<JellyfinPlaylist>> getPlaylists() async {
    // Playlists not available in offline mode (for now)
    // TODO: Could support offline playlists by caching playlist metadata
    return [];
  }

  @override
  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    final downloads = _downloadService.completedDownloads;
    final tracks = downloads
        .where((d) => d.track.albumId == albumId)
        .map((d) => d.track)
        .toList();

    // Sort by disc and track number
    tracks.sort((a, b) {
      final discCompare = (a.parentIndexNumber ?? 0).compareTo(b.parentIndexNumber ?? 0);
      if (discCompare != 0) return discCompare;
      return (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
    });

    return tracks;
  }

  @override
  Future<List<JellyfinAlbum>> getArtistAlbums(String artistId) async {
    final downloads = _downloadService.completedDownloads;
    final albums = <String, JellyfinAlbum>{};

    // Find all albums by this artist
    for (final download in downloads) {
      final track = download.track;
      if (track.artists.contains(artistId) || track.displayArtist == artistId) {
        final albumId = track.albumId ?? 'unknown';
        final albumName = track.album ?? 'Unknown Album';

        if (!albums.containsKey(albumId)) {
          albums[albumId] = JellyfinAlbum(
            id: albumId,
            name: albumName,
            artists: [track.displayArtist],
            primaryImageTag: track.albumPrimaryImageTag,
          );
        }
      }
    }

    return albums.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<List<JellyfinTrack>> getPlaylistTracks(String playlistId) async {
    // Playlists not supported in offline mode yet
    return [];
  }

  @override
  Future<List<JellyfinTrack>> getFavoriteTracks() async {
    final downloads = _downloadService.completedDownloads;
    // Return favorite tracks that are downloaded
    return downloads
        .where((d) => d.track.isFavorite)
        .map((d) => d.track)
        .toList();
  }

  @override
  Future<List<JellyfinTrack>> getRecentlyPlayedTracks({
    required String libraryId,
    int limit = 20,
  }) async {
    // Recently played not available in offline mode
    // Would need to track locally
    return [];
  }

  @override
  Future<List<JellyfinAlbum>> getRecentlyAddedAlbums({
    required String libraryId,
    int limit = 20,
  }) async {
    final downloads = _downloadService.completedDownloads;
    final albums = <String, _AlbumWithDate>{};

    // Group by album and track download date
    for (final download in downloads) {
      final track = download.track;
      final albumId = track.albumId ?? 'unknown';
      final albumName = track.album ?? 'Unknown Album';

      if (!albums.containsKey(albumId)) {
        albums[albumId] = _AlbumWithDate(
          album: JellyfinAlbum(
            id: albumId,
            name: albumName,
            artists: [track.displayArtist],
            primaryImageTag: track.albumPrimaryImageTag,
          ),
          date: download.completedAt ?? download.queuedAt,
        );
      }
    }

    // Sort by date (most recent first)
    final albumList = albums.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return albumList.take(limit).map((e) => e.album).toList();
  }

  @override
  Future<List<JellyfinTrack>> getMostPlayedTracks({
    required String libraryId,
    int limit = 20,
  }) async {
    // Play counts not tracked locally in offline mode
    return [];
  }

  @override
  Future<List<JellyfinAlbum>> getMostPlayedAlbums({
    required String libraryId,
    int limit = 20,
  }) async {
    // Play counts not tracked locally in offline mode
    return [];
  }

  @override
  Future<List<JellyfinTrack>> getLongestTracks({
    required String libraryId,
    int limit = 20,
  }) async {
    final downloads = _downloadService.completedDownloads;
    final tracks = downloads.map((d) => d.track).toList();

    // Sort by duration (longest first)
    tracks.sort((a, b) {
      final aDuration = a.duration?.inSeconds ?? 0;
      final bDuration = b.duration?.inSeconds ?? 0;
      return bDuration.compareTo(aDuration);
    });

    return tracks.take(limit).toList();
  }

  @override
  Future<List<JellyfinAlbum>> searchAlbums({
    required String query,
    required String libraryId,
  }) async {
    final albums = await getAlbums(libraryId: libraryId, limit: 1000);
    final lowerQuery = query.toLowerCase();

    return albums
        .where((album) => album.name.toLowerCase().contains(lowerQuery))
        .toList();
  }

  @override
  Future<List<JellyfinArtist>> searchArtists({
    required String query,
    required String libraryId,
  }) async {
    final artists = await getArtists(libraryId: libraryId, limit: 1000);
    final lowerQuery = query.toLowerCase();

    return artists
        .where((artist) => artist.name.toLowerCase().contains(lowerQuery))
        .toList();
  }

  @override
  Future<List<JellyfinTrack>> searchTracks({
    required String query,
    required String libraryId,
  }) async {
    final downloads = _downloadService.completedDownloads;
    final lowerQuery = query.toLowerCase();

    return downloads
        .where((d) =>
            d.track.name.toLowerCase().contains(lowerQuery) ||
            d.track.displayArtist.toLowerCase().contains(lowerQuery) ||
            (d.track.album?.toLowerCase().contains(lowerQuery) ?? false))
        .map((d) => d.track)
        .toList();
  }

  @override
  Future<List<JellyfinAlbum>> getGenreAlbums(String genreId) async {
    // Genres not supported in offline mode
    return [];
  }

  @override
  bool get isAvailable => _downloadService.completedCount > 0;

  @override
  String get typeName => 'OfflineRepository';
}

/// Helper class to track album with download date
class _AlbumWithDate {
  final JellyfinAlbum album;
  final DateTime date;

  _AlbumWithDate({required this.album, required this.date});
}
