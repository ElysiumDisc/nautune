import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';

class CarPlayService {
  final NautuneAppState appState;
  final FlutterCarplay _carplay = FlutterCarplay();
  bool _isInitialized = false;
  bool _isConnected = false;
  StreamSubscription? _playbackSubscription;
  
  CarPlayService({required this.appState});
  
  bool get isConnected => _isConnected;
  
  /// Call this after the app is fully loaded
  Future<void> initialize() async {
    if (_isInitialized || !Platform.isIOS) return;
    _isInitialized = true;
    
    // Safely setup CarPlay with error handling
    try {
      await _setupCarPlay();
      _setupListeners();
    } catch (e) {
      debugPrint('⚠️ CarPlay initialization failed (non-critical): $e');
      // Don't crash the app if CarPlay fails
    }
  }
  
  void _setupListeners() {
    // Listen to playback state changes for Now Playing updates
    _playbackSubscription = appState.audioPlayerService.currentTrackStream.listen(
      _onPlaybackChanged,
    );
    
    // Listen for CarPlay connection events using the correct API
    _carplay.addListenerOnConnectionChange((ConnectionStatusTypes status) {
      switch (status) {
        case ConnectionStatusTypes.connected:
          _onCarPlayConnect();
          break;
        case ConnectionStatusTypes.disconnected:
          _onCarPlayDisconnect();
          break;
        case ConnectionStatusTypes.background:
          debugPrint('🚗 CarPlay in background');
          break;
        case ConnectionStatusTypes.unknown:
          debugPrint('🚗 CarPlay status unknown');
          break;
      }
    });
    
    // Also listen to app state changes for library updates
    appState.addListener(_onAppStateChanged);
  }
  
  void _onCarPlayConnect() {
    _isConnected = true;
    debugPrint('🚗 CarPlay connected');
    // Refresh content when CarPlay connects
    _refreshRootTemplate();
  }
  
  void _onCarPlayDisconnect() {
    _isConnected = false;
    debugPrint('🚗 CarPlay disconnected');
  }
  
  void _onAppStateChanged() {
    if (_isConnected) {
      // Refresh content when library data changes
      _refreshRootTemplate();
    }
  }
  
  void _onPlaybackChanged(JellyfinTrack? track) {
    if (track != null && _isConnected) {
      updateNowPlaying(
        trackId: track.id,
        title: track.name,
        artist: track.displayArtist,
        album: track.album,
      );
    }
  }
  
  Future<void> _refreshRootTemplate() async {
    if (!_isInitialized || !_isConnected) return;
    try {
      final rootTemplate = _buildRootTemplate();
      await FlutterCarplay.setRootTemplate(
        rootTemplate: rootTemplate,
        animated: false,
      );
      debugPrint('🔄 CarPlay content refreshed');
    } catch (e) {
      debugPrint('⚠️ CarPlay refresh error: $e');
    }
  }
  
  Future<void> _setupCarPlay() async {
    try {
      // Build the root template
      final rootTemplate = _buildRootTemplate();
      
      // Set root template using the static method (CRITICAL!)
      await FlutterCarplay.setRootTemplate(
        rootTemplate: rootTemplate,
        animated: true,
      );
      
      // Force update to ensure CarPlay shows it
      await _carplay.forceUpdateRootTemplate();
      
      debugPrint('✅ CarPlay root template set successfully');
    } catch (e) {
      debugPrint('⚠️ CarPlay setup error: $e');
    }
  }
  
  CPTabBarTemplate _buildRootTemplate() {
    final libraryTab = CPListTemplate(
      title: 'Library',
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: 'Albums',
              detailText: 'Browse all albums',
              onPress: (complete, self) async {
                await _showAlbums();
                complete();
              },
            ),
            CPListItem(
              text: 'Artists',
              detailText: 'Browse all artists',
              onPress: (complete, self) async {
                await _showArtists();
                complete();
              },
            ),
            CPListItem(
              text: 'Playlists',
              detailText: 'Your playlists',
              onPress: (complete, self) async {
                await _showPlaylists();
                complete();
              },
            ),
          ],
        ),
      ],
      systemIcon: 'music.note.house',
    );

    final favoritesTab = CPListTemplate(
      title: 'Favorites',
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: 'Favorite Tracks',
              detailText: 'Your hearted songs',
              onPress: (complete, self) async {
                await _showFavorites();
                complete();
              },
            ),
          ],
        ),
      ],
      systemIcon: 'heart.fill',
    );

    final downloadsTab = CPListTemplate(
      title: 'Downloads',
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: 'Downloaded Music',
              detailText: 'Available offline',
              onPress: (complete, self) async {
                await _showDownloads();
                complete();
              },
            ),
          ],
        ),
      ],
      systemIcon: 'arrow.down.circle.fill',
    );

    return CPTabBarTemplate(
      templates: [libraryTab, favoritesTab, downloadsTab],
    );
  }

  Future<void> _showAlbums() async {
    final albumsList = appState.albums ?? [];

    if (albumsList.isEmpty) {
      await _showEmptyState('Albums', 'No albums available');
      return;
    }

    final items = albumsList.map((album) => CPListItem(
      text: album.name,
      detailText: album.artists.join(', '),
      onPress: (complete, self) async {
        await _showAlbumTracks(album.id, album.name);
        complete();
      },
    )).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: 'Albums',
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note.list',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Albums failed: $e');
    }
  }

  Future<void> _showArtists() async {
    final artistsList = appState.artists ?? [];

    if (artistsList.isEmpty) {
      await _showEmptyState('Artists', 'No artists available');
      return;
    }

    final items = artistsList.map((artist) => CPListItem(
      text: artist.name,
      onPress: (complete, self) async {
        await _showArtistAlbums(artist.id, artist.name);
        complete();
      },
    )).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: 'Artists',
          sections: [CPListSection(items: items)],
          systemIcon: 'music.mic',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Artists failed: $e');
    }
  }

  Future<void> _showPlaylists() async {
    final playlistsList = appState.playlists ?? [];

    if (playlistsList.isEmpty) {
      await _showEmptyState('Playlists', 'No playlists available');
      return;
    }

    final items = playlistsList.map((playlist) => CPListItem(
      text: playlist.name,
      detailText: '${playlist.trackCount} tracks',
      onPress: (complete, self) async {
        await _showPlaylistTracks(playlist.id, playlist.name);
        complete();
      },
    )).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: 'Playlists',
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note.list',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Playlists failed: $e');
    }
  }

  Future<void> _showAlbumTracks(String albumId, String albumName) async {
    final tracks = await appState.getAlbumTracks(albumId);

    if (tracks.isEmpty) {
      await _showEmptyState(albumName, 'No tracks in this album');
      return;
    }

    final items = tracks.map((track) {
      return CPListItem(
        text: track.name,
        detailText: track.artists.join(', '),
        onPress: (complete, self) {
          // Play track with album as queue context
          appState.audioPlayerService.playTrack(
            track,
            queueContext: tracks,
            reorderQueue: false,
          );
          complete();
        },
      );
    }).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: albumName,
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push AlbumTracks failed: $e');
    }
  }

  Future<void> _showArtistAlbums(String artistId, String artistName) async {
    final albumsList = appState.albums ?? [];
    final albums = albumsList.where((album) {
      if (album.artistIds.contains(artistId)) {
        return true;
      }
      return album.artists.contains(artistName);
    }).toList();

    if (albums.isEmpty) {
      await _showEmptyState(artistName, 'No albums from this artist');
      return;
    }

    final items = albums.map((album) => CPListItem(
      text: album.name,
      detailText: album.artists.join(', '),
      onPress: (complete, self) async {
        await _showAlbumTracks(album.id, album.name);
        complete();
      },
    )).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: artistName,
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note.list',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push ArtistAlbums failed: $e');
    }
  }

  Future<void> _showPlaylistTracks(String playlistId, String playlistName) async {
    final tracks = await appState.getPlaylistTracks(playlistId);

    if (tracks.isEmpty) {
      await _showEmptyState(playlistName, 'No tracks in this playlist');
      return;
    }

    final items = tracks.map((track) {
      return CPListItem(
        text: track.name,
        detailText: track.artists.join(', '),
        onPress: (complete, self) {
          // Play track with playlist as queue context
          appState.audioPlayerService.playTrack(
            track,
            queueContext: tracks,
            reorderQueue: false,
          );
          complete();
        },
      );
    }).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: playlistName,
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push PlaylistTracks failed: $e');
    }
  }

  Future<void> _showFavorites() async {
    // Use favorite tracks directly instead of fetching from albums
    final favoriteTracks = appState.favoriteTracks ?? [];

    if (favoriteTracks.isEmpty) {
      await _showEmptyState('Favorites', 'No favorite tracks yet');
      return;
    }

    final items = favoriteTracks.map((track) => CPListItem(
      text: track.name,
      detailText: '${track.artists.join(', ')} • ${track.album}',
      onPress: (complete, self) {
        // Play track with favorites as queue context
        appState.audioPlayerService.playTrack(
          track,
          queueContext: favoriteTracks,
          reorderQueue: false,
        );
        complete();
      },
    )).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: 'Favorites',
          sections: [CPListSection(items: items)],
          systemIcon: 'heart.fill',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Favorites failed: $e');
    }
  }

  Future<void> _showDownloads() async {
    final downloads = appState.downloadService.completedDownloads;

    if (downloads.isEmpty) {
      await _showEmptyState('Downloads', 'No downloaded music');
      return;
    }

    final downloadedTracks = downloads.map((d) => d.track).toList();
    final items = downloads.map((download) => CPListItem(
      text: download.track.name,
      detailText: '${download.track.artists.join(', ')} • ${download.track.album}',
      onPress: (complete, self) {
        // Play track with downloads as queue context
        appState.audioPlayerService.playTrack(
          download.track,
          queueContext: downloadedTracks,
          reorderQueue: false,
        );
        complete();
      },
    )).toList();

    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: 'Downloads',
          sections: [CPListSection(items: items)],
          systemIcon: 'arrow.down.circle',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Downloads failed: $e');
    }
  }

  Future<void> _showEmptyState(String title, String message) async {
    try {
      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
          sections: [
            CPListSection(
              items: [
                CPListItem(
                  text: message,
                  detailText: appState.isOfflineMode
                      ? 'You are offline. Downloaded music is available.'
                      : 'Try refreshing your library',
                  onPress: (complete, self) {
                    complete();
                  },
                ),
              ],
            ),
          ],
          systemIcon: 'exclamationmark.circle',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push EmptyState failed: $e');
    }
  }

  void updateNowPlaying({
    required String trackId,
    required String title,
    required String artist,
    String? album,
  }) {
    // Now Playing info is handled by audio_service plugin automatically
    // This method is kept for API compatibility and potential future extensions
  }
  
  void dispose() {
    _playbackSubscription?.cancel();
    _carplay.removeListenerOnConnectionChange();
    appState.removeListener(_onAppStateChanged);
  }
}
