import 'dart:io';
import 'package:flutter_carplay/flutter_carplay.dart';
import '../app_state.dart';

class CarPlayService {
  final NautuneAppState appState;
  final FlutterCarplay _carplay = FlutterCarplay();
  bool _isInitialized = false;
  
  CarPlayService({required this.appState});
  
  /// Call this after the app is fully loaded
  void initialize() {
    if (_isInitialized || !Platform.isIOS) return;
    _isInitialized = true;
    
    // Safely setup CarPlay with error handling
    try {
      _setupCarPlay();
    } catch (e) {
      print('⚠️ CarPlay initialization failed (non-critical): $e');
      // Don't crash the app if CarPlay fails
    }
  }
  
  void _setupCarPlay() async {
    try {
      // Set root template first, then force update
      _setRootTemplate();
      await _carplay.forceUpdateRootTemplate();
    } catch (e) {
      print('⚠️ CarPlay setup error: $e');
    }
  }
  
  void _setRootTemplate() {
    final libraryTab = CPListTemplate(
      title: 'Library',
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: 'Albums',
              detailText: 'Browse all albums',
              onPress: (complete, self) {
                _showAlbums();
                complete();
              },
            ),
            CPListItem(
              text: 'Artists',
              detailText: 'Browse all artists',
              onPress: (complete, self) {
                _showArtists();
                complete();
              },
            ),
            CPListItem(
              text: 'Playlists',
              detailText: 'Your playlists',
              onPress: (complete, self) {
                _showPlaylists();
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
              onPress: (complete, self) {
                _showFavorites();
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
              onPress: (complete, self) {
                _showDownloads();
                complete();
              },
            ),
          ],
        ),
      ],
      systemIcon: 'arrow.down.circle.fill',
    );

    FlutterCarplay.setRootTemplate(
      rootTemplate: CPTabBarTemplate(
        templates: [libraryTab, favoritesTab, downloadsTab],
      ),
      animated: true,
    );
  }

  void _showAlbums() async {
    final albumsList = appState.albums ?? [];
    final items = albumsList.map((album) => CPListItem(
      text: album.name,
      detailText: album.artists.join(', '),
      onPress: (complete, self) {
        _showAlbumTracks(album.id, album.name);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: 'Albums',
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note.list',
      ),
    );
  }

  void _showArtists() async {
    final artistsList = appState.artists ?? [];
    final items = artistsList.map((artist) => CPListItem(
      text: artist.name,
      onPress: (complete, self) {
        _showArtistAlbums(artist.id, artist.name);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: 'Artists',
        sections: [CPListSection(items: items)],
        systemIcon: 'music.mic',
      ),
    );
  }

  void _showPlaylists() async {
    final playlistsList = appState.playlists ?? [];
    final items = playlistsList.map((playlist) => CPListItem(
      text: playlist.name,
      detailText: '${playlist.trackCount} tracks',
      onPress: (complete, self) {
        _showPlaylistTracks(playlist.id, playlist.name);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: 'Playlists',
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note.list',
      ),
    );
  }

  void _showAlbumTracks(String albumId, String albumName) async {
    final tracks = await appState.getAlbumTracks(albumId);
    final items = tracks.map((track) => CPListItem(
      text: track.name,
      detailText: track.artists.join(', '),
      onPress: (complete, self) {
        appState.audioPlayerService.playTrack(track);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: albumName,
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note',
      ),
    );
  }

  void _showArtistAlbums(String artistId, String artistName) async {
    final albumsList = appState.albums ?? [];
    final albums = albumsList.where((album) {
      if (album.artistIds.contains(artistId)) {
        return true;
      }
      return album.artists.contains(artistName);
    }).toList();
    
    final items = albums.map((album) => CPListItem(
      text: album.name,
      detailText: album.artists.join(', '),
      onPress: (complete, self) {
        _showAlbumTracks(album.id, album.name);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: artistName,
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note.list',
      ),
    );
  }

  void _showPlaylistTracks(String playlistId, String playlistName) async {
    final tracks = await appState.getPlaylistTracks(playlistId);
    final items = tracks.map((track) => CPListItem(
      text: track.name,
      detailText: track.artists.join(', '),
      onPress: (complete, self) {
        appState.audioPlayerService.playTrack(track);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: playlistName,
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note',
      ),
    );
  }

  void _showFavorites() async {
    final albumsList = appState.albums ?? [];
    final favorites = albumsList.where((album) => album.isFavorite).toList();
    
    final List<CPListItem> favoriteTracks = [];
    for (final album in favorites) {
      final tracks = await appState.getAlbumTracks(album.id);
      favoriteTracks.addAll(tracks.map((track) => CPListItem(
        text: track.name,
        detailText: '${track.artists.join(', ')} • ${track.album}',
        onPress: (complete, self) {
          appState.audioPlayerService.playTrack(track);
          complete();
        },
      )));
    }

    FlutterCarplay.push(
      template: CPListTemplate(
        title: 'Favorites',
        sections: [CPListSection(items: favoriteTracks)],
        systemIcon: 'heart.fill',
      ),
    );
  }

  void _showDownloads() async {
    final downloads = appState.downloadService.completedDownloads;
    final items = downloads.map((download) => CPListItem(
      text: download.track.name,
      detailText: '${download.track.artists.join(', ')} • ${download.track.album}',
      onPress: (complete, self) {
        appState.audioPlayerService.playTrack(download.track);
        complete();
      },
    )).toList();

    FlutterCarplay.push(
      template: CPListTemplate(
        title: 'Downloads',
        sections: [CPListSection(items: items)],
        systemIcon: 'arrow.down.circle',
      ),
    );
  }

  void updateNowPlaying({
    required String trackId,
    required String title,
    required String artist,
    String? album,
  }) {
    // Now Playing info is handled by audio_service plugin automatically
  }
}
