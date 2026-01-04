import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';

/// Sort options for albums and artists
enum SortOption {
  name,       // Sort by name (default)
  dateAdded,  // Sort by date added to library
  year,       // Sort by release year
  playCount,  // Sort by play count
}

/// Sort order
enum SortOrder {
  ascending,
  descending,
}

/// Convert SortOption to Jellyfin API parameter
String sortOptionToJellyfin(SortOption option) {
  switch (option) {
    case SortOption.name:
      return 'SortName';
    case SortOption.dateAdded:
      return 'DateCreated';
    case SortOption.year:
      return 'ProductionYear,SortName';
    case SortOption.playCount:
      return 'PlayCount';
  }
}

/// Convert SortOrder to Jellyfin API parameter
String sortOrderToJellyfin(SortOrder order) {
  switch (order) {
    case SortOrder.ascending:
      return 'Ascending';
    case SortOrder.descending:
      return 'Descending';
  }
}

/// Abstract repository interface for music data.
///
/// Implementations:
/// - OnlineRepository: Fetches from Jellyfin server via JellyfinService
/// - OfflineRepository: Queries local downloads database (Hive)
///
/// This abstraction allows the UI to be agnostic of the data source,
/// enabling seamless online/offline mode switching.
abstract class MusicRepository {
  /// Get all available music libraries
  Future<List<JellyfinLibrary>> getLibraries();

  /// Get albums for a specific library with pagination
  Future<List<JellyfinAlbum>> getAlbums({
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
    SortOption sortBy = SortOption.name,
    SortOrder sortOrder = SortOrder.ascending,
  });

  /// Get artists for a specific library with pagination
  Future<List<JellyfinArtist>> getArtists({
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
    SortOption sortBy = SortOption.name,
    SortOrder sortOrder = SortOrder.ascending,
  });

  /// Get genres for a specific library
  Future<List<JellyfinGenre>> getGenres({required String libraryId});

  /// Get all user playlists
  Future<List<JellyfinPlaylist>> getPlaylists();

  /// Get tracks for a specific album
  Future<List<JellyfinTrack>> getAlbumTracks(String albumId);

  /// Get all albums by a specific artist
  Future<List<JellyfinAlbum>> getArtistAlbums(String artistId);

  /// Get items in a playlist
  Future<List<JellyfinTrack>> getPlaylistTracks(String playlistId);

  /// Get user's favorite tracks
  Future<List<JellyfinTrack>> getFavoriteTracks();

  /// Get recently played tracks
  Future<List<JellyfinTrack>> getRecentlyPlayedTracks({
    required String libraryId,
    int limit = 20,
  });

  /// Get recently added albums
  Future<List<JellyfinAlbum>> getRecentlyAddedAlbums({
    required String libraryId,
    int limit = 20,
  });

  /// Get most played tracks
  Future<List<JellyfinTrack>> getMostPlayedTracks({
    required String libraryId,
    int limit = 20,
  });

  /// Get most played albums
  Future<List<JellyfinAlbum>> getMostPlayedAlbums({
    required String libraryId,
    int limit = 20,
  });

  /// Get longest runtime tracks
  Future<List<JellyfinTrack>> getLongestTracks({
    required String libraryId,
    int limit = 20,
  });

  /// Search for albums by name
  Future<List<JellyfinAlbum>> searchAlbums({
    required String query,
    required String libraryId,
  });

  /// Search for artists by name
  Future<List<JellyfinArtist>> searchArtists({
    required String query,
    required String libraryId,
  });

  /// Search for tracks by name
  Future<List<JellyfinTrack>> searchTracks({
    required String query,
    required String libraryId,
  });

  /// Get albums for a specific genre
  Future<List<JellyfinAlbum>> getGenreAlbums(String genreId);

  /// Check if repository is currently available
  bool get isAvailable;

  /// Get repository type name for debugging
  String get typeName;
}
