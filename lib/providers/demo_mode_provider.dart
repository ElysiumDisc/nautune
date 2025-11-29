import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../demo/demo_content.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/download_service.dart';
import 'session_provider.dart';

/// Manages demo mode state and content.
///
/// Responsibilities:
/// - Enable/disable demo mode
/// - Provide demo content (albums, artists, tracks, playlists)
/// - Manage demo-specific state (favorites, recent tracks)
/// - Coordinate with SessionProvider for demo session
/// - Coordinate with DownloadService for demo downloads
///
/// Demo mode allows users to explore the app without a Jellyfin server.
class DemoModeProvider extends ChangeNotifier {
  DemoModeProvider({
    required SessionProvider sessionProvider,
    required DownloadService downloadService,
  })  : _sessionProvider = sessionProvider,
        _downloadService = downloadService;

  final SessionProvider _sessionProvider;
  final DownloadService _downloadService;

  bool _isDemoMode = false;
  DemoContent? _demoContent;
  Map<String, JellyfinTrack> _demoTracks = {};
  Map<String, List<String>> _demoAlbumTrackMap = {};
  Map<String, List<String>> _demoPlaylistTrackMap = {};
  List<String> _demoRecentTrackIds = [];
  Set<String> _demoFavoriteTrackIds = <String>{};
  int _demoPlaylistCounter = 0;

  // Getters
  bool get isDemoMode => _isDemoMode;
  List<JellyfinAlbum> get albums => _demoContent?.albums ?? const <JellyfinAlbum>[];
  List<JellyfinArtist> get artists => _demoContent?.artists ?? const <JellyfinArtist>[];
  List<JellyfinGenre> get genres => _demoContent?.genres ?? const <JellyfinGenre>[];
  List<JellyfinPlaylist> get playlists {
    if (!_isDemoMode || _demoContent == null) return const [];
    return _demoContent!.playlists;
  }

  JellyfinLibrary? get library => _demoContent?.library;

  List<JellyfinTrack> get recentTracks => _tracksFromIds(_demoRecentTrackIds);
  List<JellyfinTrack> get favoriteTracks => _tracksFromIds(_demoFavoriteTrackIds.toList());
  List<JellyfinTrack> get allTracks => _demoTracks.values.toList(growable: false);

  List<JellyfinTrack> _tracksFromIds(List<String> ids) {
    if (!_isDemoMode) return const [];
    return ids
        .map((id) => _demoTracks[id])
        .whereType<JellyfinTrack>()
        .toList();
  }

  /// Start demo mode with demo content.
  ///
  /// This loads demo assets, sets up demo session, and seeds demo downloads.
  Future<void> startDemoMode() async {
    debugPrint('DemoModeProvider: Starting demo mode...');

    try {
      // Load demo audio asset
      final data = await rootBundle.load('assets/demo/demo_offline_track.mp3');
      final offlineAudioBytes = data.buffer.asUint8List();

      // Clean up any existing demo state
      await stopDemoMode();

      // Enable demo mode in download service
      _downloadService.enableDemoMode(demoAudioBytes: offlineAudioBytes);

      // Setup demo content
      final content = DemoContent();
      _demoContent = content;
      _isDemoMode = true;
      _demoTracks = Map<String, JellyfinTrack>.from(content.tracks);
      _demoAlbumTrackMap = content.albumTrackIds.map(
        (key, value) => MapEntry(key, List<String>.from(value)),
      );
      _demoPlaylistTrackMap = content.playlistTrackIds.map(
        (key, value) => MapEntry(key, List<String>.from(value)),
      );
      _demoRecentTrackIds = List<String>.from(content.recentTrackIds);
      _demoFavoriteTrackIds = content.favoriteTrackIds.toSet();
      _demoPlaylistCounter = content.playlists.length;

      // Create demo session
      await _sessionProvider.startDemoSession(
        libraryId: content.library.id,
        libraryName: content.library.name,
      );

      // Seed offline download for demo
      final offlineTrack = _demoTracks[content.offlineTrackId];
      if (offlineTrack != null) {
        await _downloadService.seedDemoDownload(
          track: offlineTrack,
          bytes: offlineAudioBytes,
          extension: 'mp3',
        );
      }

      debugPrint('DemoModeProvider: Demo mode started successfully');
      notifyListeners();
    } catch (error) {
      debugPrint('DemoModeProvider: Failed to start demo mode: $error');
      await stopDemoMode();
      rethrow;
    }
  }

  /// Stop demo mode and clean up demo data.
  Future<void> stopDemoMode() async {
    if (!_isDemoMode) return;

    debugPrint('DemoModeProvider: Stopping demo mode...');

    try {
      // Clean up demo downloads
      await _downloadService.deleteDemoDownloads();
      _downloadService.disableDemoMode();

      // Clear demo state
      _isDemoMode = false;
      _demoContent = null;
      _demoTracks = {};
      _demoAlbumTrackMap = {};
      _demoPlaylistTrackMap = {};
      _demoFavoriteTrackIds.clear();
      _demoRecentTrackIds = [];
      _demoPlaylistCounter = 0;

      notifyListeners();
    } catch (error) {
      debugPrint('DemoModeProvider: Error stopping demo mode: $error');
    }
  }

  /// Get tracks for a demo album.
  List<JellyfinTrack> getAlbumTracks(String albumId) {
    final ids = _demoAlbumTrackMap[albumId] ?? const <String>[];
    return _tracksFromIds(ids);
  }

  /// Get tracks for a demo playlist.
  List<JellyfinTrack> getPlaylistTracks(String playlistId) {
    final ids = _demoPlaylistTrackMap[playlistId] ?? const <String>[];
    return _tracksFromIds(ids);
  }

  /// Create a demo playlist.
  JellyfinPlaylist createPlaylist({
    required String name,
    List<String>? itemIds,
  }) {
    _demoPlaylistCounter++;
    final playlistId = 'demo-playlist-$_demoPlaylistCounter';
    final tracks = List<String>.from(itemIds ?? const <String>[]);

    final playlist = JellyfinPlaylist(
      id: playlistId,
      name: name,
      trackCount: tracks.length,
    );

    _demoPlaylistTrackMap[playlistId] = tracks;

    // Update playlists list directly instead of using copyWith
    if (_demoContent != null) {
      _demoContent!.playlists = [..._demoContent!.playlists, playlist];
    }

    notifyListeners();
    return playlist;
  }

  /// Update a demo playlist's name.
  void updatePlaylist({
    required String playlistId,
    required String newName,
  }) {
    final existing = playlists.where((p) => p.id == playlistId).firstOrNull;
    if (existing == null) return;

    final updated = JellyfinPlaylist(
      id: existing.id,
      name: newName,
      trackCount: existing.trackCount,
    );

    final updatedPlaylists = playlists.map((p) {
      return p.id == playlistId ? updated : p;
    }).toList();

    if (_demoContent != null) {
      _demoContent!.playlists = updatedPlaylists;
    }

    notifyListeners();
  }

  /// Delete a demo playlist.
  void deletePlaylist(String playlistId) {
    _demoPlaylistTrackMap.remove(playlistId);

    final updatedPlaylists = playlists.where((p) => p.id != playlistId).toList();

    if (_demoContent != null) {
      _demoContent!.playlists = updatedPlaylists;
    }

    notifyListeners();
  }

  /// Add tracks to a demo playlist.
  void addToPlaylist({
    required String playlistId,
    required List<String> itemIds,
  }) {
    final existing = _demoPlaylistTrackMap[playlistId] ?? <String>[];
    final updated = List<String>.from(existing)..addAll(itemIds);
    _demoPlaylistTrackMap[playlistId] = updated;

    final playlist = playlists.where((p) => p.id == playlistId).firstOrNull;
    if (playlist != null) {
      final updatedPlaylist = JellyfinPlaylist(
        id: playlist.id,
        name: playlist.name,
        trackCount: updated.length,
      );

      final updatedPlaylists = playlists.map((p) {
        return p.id == playlistId ? updatedPlaylist : p;
      }).toList();

      if (_demoContent != null) {
        _demoContent!.playlists = updatedPlaylists;
      }
    }

    notifyListeners();
  }

  /// Mark a demo track as favorite/unfavorite.
  void markFavorite(String itemId, bool shouldBeFavorite) {
    final existing = _demoTracks[itemId];
    if (existing == null) return;

    _demoTracks[itemId] = existing.copyWith(isFavorite: shouldBeFavorite);

    if (shouldBeFavorite) {
      _demoFavoriteTrackIds.add(itemId);
    } else {
      _demoFavoriteTrackIds.remove(itemId);
    }

    notifyListeners();
  }
}
