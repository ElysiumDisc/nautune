import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import 'music_repository.dart';

/// Online implementation of MusicRepository.
///
/// Fetches all data from Jellyfin server via JellyfinService.
/// Used when the app is in online mode with network connectivity.
class OnlineRepository implements MusicRepository {
  OnlineRepository({required JellyfinService jellyfinService})
      : _jellyfinService = jellyfinService;

  final JellyfinService _jellyfinService;

  @override
  Future<List<JellyfinLibrary>> getLibraries() async {
    return await _jellyfinService.loadLibraries();
  }

  @override
  Future<List<JellyfinAlbum>> getAlbums({
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
  }) async {
    return await _jellyfinService.loadAlbums(
      libraryId: libraryId,
      startIndex: startIndex,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinArtist>> getArtists({
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
  }) async {
    return await _jellyfinService.loadArtists(
      libraryId: libraryId,
      startIndex: startIndex,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinGenre>> getGenres({required String libraryId}) async {
    return await _jellyfinService.loadGenres(libraryId: libraryId);
  }

  @override
  Future<List<JellyfinPlaylist>> getPlaylists() async {
    return await _jellyfinService.loadPlaylists();
  }

  @override
  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    return await _jellyfinService.getAlbumTracks(albumId);
  }

  @override
  Future<List<JellyfinAlbum>> getArtistAlbums(String artistId) async {
    return await _jellyfinService.loadAlbumsByArtist(artistId: artistId);
  }

  @override
  Future<List<JellyfinTrack>> getPlaylistTracks(String playlistId) async {
    return await _jellyfinService.getPlaylistItems(playlistId);
  }

  @override
  Future<List<JellyfinTrack>> getFavoriteTracks() async {
    return await _jellyfinService.getFavoriteTracks();
  }

  @override
  Future<List<JellyfinTrack>> getRecentlyPlayedTracks({
    required String libraryId,
    int limit = 20,
  }) async {
    return await _jellyfinService.getRecentlyPlayedTracks(
      libraryId: libraryId,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinAlbum>> getRecentlyAddedAlbums({
    required String libraryId,
    int limit = 20,
  }) async {
    return await _jellyfinService.loadRecentlyAddedAlbums(
      libraryId: libraryId,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinTrack>> getMostPlayedTracks({
    required String libraryId,
    int limit = 20,
  }) async {
    return await _jellyfinService.getMostPlayedTracks(
      libraryId: libraryId,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinAlbum>> getMostPlayedAlbums({
    required String libraryId,
    int limit = 20,
  }) async {
    return await _jellyfinService.getMostPlayedAlbums(
      libraryId: libraryId,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinTrack>> getLongestTracks({
    required String libraryId,
    int limit = 20,
  }) async {
    return await _jellyfinService.getLongestRuntimeTracks(
      libraryId: libraryId,
      limit: limit,
    );
  }

  @override
  Future<List<JellyfinAlbum>> searchAlbums({
    required String query,
    required String libraryId,
  }) async {
    return await _jellyfinService.searchAlbums(
      query: query,
      libraryId: libraryId,
    );
  }

  @override
  Future<List<JellyfinArtist>> searchArtists({
    required String query,
    required String libraryId,
  }) async {
    return await _jellyfinService.searchArtists(
      query: query,
      libraryId: libraryId,
    );
  }

  @override
  Future<List<JellyfinTrack>> searchTracks({
    required String query,
    required String libraryId,
  }) async {
    return await _jellyfinService.searchTracks(
      query: query,
      libraryId: libraryId,
    );
  }

  @override
  Future<List<JellyfinAlbum>> getGenreAlbums(String genreId) async {
    // Genre albums are loaded via loadAlbums with genreIds filter
    // The genre detail screen handles this directly via JellyfinClient
    // For now, this repository method isn't used by UI
    return [];
  }

  @override
  bool get isAvailable {
    // Check if we have a valid session
    try {
      final url = _jellyfinService.baseUrl;
      return url != null && url.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  @override
  String get typeName => 'OnlineRepository';
}
