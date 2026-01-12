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
  bool _isNavigating = false; // Prevents root refresh during navigation
  StreamSubscription? _playbackSubscription;
  Timer? _refreshDebounceTimer;

  // Pagination limits for CarPlay (prevents performance issues with large libraries)
  static const int _maxItemsPerPage = 100;

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
    if (_isConnected && !_isNavigating) {
      // Debounce refresh to avoid excessive updates during rapid state changes
      _refreshDebounceTimer?.cancel();
      _refreshDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (_isConnected && !_isNavigating) {
          _refreshRootTemplate();
        }
      });
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
              detailText: _getAlbumCount(),
              onPress: (complete, self) async {
                _isNavigating = true;
                try {
                  await _showAlbums();
                } finally {
                  _isNavigating = false;
                  complete();
                }
              },
            ),
            CPListItem(
              text: 'Artists',
              detailText: _getArtistCount(),
              onPress: (complete, self) async {
                _isNavigating = true;
                try {
                  await _showArtists();
                } finally {
                  _isNavigating = false;
                  complete();
                }
              },
            ),
            CPListItem(
              text: 'Playlists',
              detailText: _getPlaylistCount(),
              onPress: (complete, self) async {
                _isNavigating = true;
                try {
                  await _showPlaylists();
                } finally {
                  _isNavigating = false;
                  complete();
                }
              },
            ),
          ],
        ),
      ],
      systemIcon: 'music.note.house',
    );

    final recentTab = CPListTemplate(
      title: 'Recent',
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: 'Recently Played',
              detailText: 'Your listening history',
              onPress: (complete, self) async {
                _isNavigating = true;
                try {
                  await _showRecentlyPlayed();
                } finally {
                  _isNavigating = false;
                  complete();
                }
              },
            ),
            CPListItem(
              text: 'Favorite Tracks',
              detailText: _getFavoriteCount(),
              onPress: (complete, self) async {
                _isNavigating = true;
                try {
                  await _showFavorites();
                } finally {
                  _isNavigating = false;
                  complete();
                }
              },
            ),
          ],
        ),
      ],
      systemIcon: 'clock.fill',
    );

    final downloadsTab = CPListTemplate(
      title: 'Downloads',
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: 'Downloaded Music',
              detailText: _getDownloadCount(),
              onPress: (complete, self) async {
                _isNavigating = true;
                try {
                  await _showDownloads();
                } finally {
                  _isNavigating = false;
                  complete();
                }
              },
            ),
          ],
        ),
      ],
      systemIcon: 'arrow.down.circle.fill',
    );

    return CPTabBarTemplate(
      templates: [libraryTab, recentTab, downloadsTab],
    );
  }

  // Helper methods for dynamic counts
  String _getAlbumCount() {
    final count = appState.albums?.length ?? 0;
    if (appState.isLoadingAlbums) return 'Loading...';
    return count > 0 ? '$count albums' : 'Browse all albums';
  }

  String _getArtistCount() {
    final count = appState.artists?.length ?? 0;
    if (appState.isLoadingArtists) return 'Loading...';
    return count > 0 ? '$count artists' : 'Browse all artists';
  }

  String _getPlaylistCount() {
    final count = appState.playlists?.length ?? 0;
    if (appState.isLoadingPlaylists) return 'Loading...';
    return count > 0 ? '$count playlists' : 'Your playlists';
  }

  String _getFavoriteCount() {
    final count = appState.favoriteTracks?.length ?? 0;
    if (appState.isLoadingFavorites) return 'Loading...';
    return count > 0 ? '$count songs' : 'Your hearted songs';
  }

  String _getDownloadCount() {
    final count = appState.downloadService.completedDownloads.length;
    return count > 0 ? '$count songs available offline' : 'Available offline';
  }

  /// Wait for a condition to be met with a timeout
  Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition() && DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _showAlbums({int offset = 0}) async {
    try {
      // If we don't have data and aren't loading, trigger load
      if (appState.albums == null && !appState.isLoadingAlbums) {
        // Trigger load without awaiting (to start the process)
        appState.refreshAlbums();
      }

      // If loading, wait for it to finish
      if (appState.isLoadingAlbums) {
        await _waitFor(() => !appState.isLoadingAlbums);
      }

      final allAlbums = appState.albums ?? [];

      if (allAlbums.isEmpty) {
        await _showEmptyState('Albums', 'No albums available');
        return;
      }

      // Paginate the list
      final paginatedAlbums = allAlbums.skip(offset).take(_maxItemsPerPage).toList();
      final hasMore = offset + _maxItemsPerPage < allAlbums.length;
      final totalCount = allAlbums.length;

      final items = paginatedAlbums.map((album) => CPListItem(
        text: album.name,
        detailText: album.artists.join(', '),
        onPress: (complete, self) async {
          _isNavigating = true;
          try {
            await _showAlbumTracks(album.id, album.name);
          } finally {
            _isNavigating = false;
            complete();
          }
        },
      )).toList();

      // Add "Load More" item if there are more albums
      if (hasMore) {
        final remaining = totalCount - (offset + _maxItemsPerPage);
        items.add(CPListItem(
          text: 'Load More...',
          detailText: '$remaining more albums',
          onPress: (complete, self) async {
            _isNavigating = true;
            try {
              await _showAlbums(offset: offset + _maxItemsPerPage);
            } finally {
              _isNavigating = false;
              complete();
            }
          },
        ));
      }

      final title = offset > 0
          ? 'Albums (${offset + 1}-${offset + paginatedAlbums.length} of $totalCount)'
          : 'Albums ($totalCount)';

      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note.list',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Albums failed: $e');
    }
  }

  Future<void> _showArtists({int offset = 0}) async {
    try {
      if (appState.artists == null && !appState.isLoadingArtists) {
        appState.refreshArtists();
      }

      if (appState.isLoadingArtists) {
        await _waitFor(() => !appState.isLoadingArtists);
      }

      final allArtists = appState.artists ?? [];

      if (allArtists.isEmpty) {
        await _showEmptyState('Artists', 'No artists available');
        return;
      }

      // Paginate the list
      final paginatedArtists = allArtists.skip(offset).take(_maxItemsPerPage).toList();
      final hasMore = offset + _maxItemsPerPage < allArtists.length;
      final totalCount = allArtists.length;

      final items = paginatedArtists.map((artist) => CPListItem(
        text: artist.name,
        onPress: (complete, self) async {
          _isNavigating = true;
          try {
            await _showArtistAlbums(artist.id, artist.name);
          } finally {
            _isNavigating = false;
            complete();
          }
        },
      )).toList();

      // Add "Load More" item if there are more artists
      if (hasMore) {
        final remaining = totalCount - (offset + _maxItemsPerPage);
        items.add(CPListItem(
          text: 'Load More...',
          detailText: '$remaining more artists',
          onPress: (complete, self) async {
            _isNavigating = true;
            try {
              await _showArtists(offset: offset + _maxItemsPerPage);
            } finally {
              _isNavigating = false;
              complete();
            }
          },
        ));
      }

      final title = offset > 0
          ? 'Artists (${offset + 1}-${offset + paginatedArtists.length} of $totalCount)'
          : 'Artists ($totalCount)';

      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
          sections: [CPListSection(items: items)],
          systemIcon: 'music.mic',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Artists failed: $e');
    }
  }

  Future<void> _showPlaylists({int offset = 0}) async {
    try {
      if (appState.playlists == null && !appState.isLoadingPlaylists) {
        appState.refreshPlaylists();
      }

      if (appState.isLoadingPlaylists) {
        await _waitFor(() => !appState.isLoadingPlaylists);
      }

      final allPlaylists = appState.playlists ?? [];

      if (allPlaylists.isEmpty) {
        await _showEmptyState('Playlists', 'No playlists available');
        return;
      }

      // Paginate the list
      final paginatedPlaylists = allPlaylists.skip(offset).take(_maxItemsPerPage).toList();
      final hasMore = offset + _maxItemsPerPage < allPlaylists.length;
      final totalCount = allPlaylists.length;

      final items = paginatedPlaylists.map((playlist) => CPListItem(
        text: playlist.name,
        detailText: '${playlist.trackCount} tracks',
        onPress: (complete, self) async {
          _isNavigating = true;
          try {
            await _showPlaylistTracks(playlist.id, playlist.name);
          } finally {
            _isNavigating = false;
            complete();
          }
        },
      )).toList();

      // Add "Load More" item if there are more playlists
      if (hasMore) {
        final remaining = totalCount - (offset + _maxItemsPerPage);
        items.add(CPListItem(
          text: 'Load More...',
          detailText: '$remaining more playlists',
          onPress: (complete, self) async {
            _isNavigating = true;
            try {
              await _showPlaylists(offset: offset + _maxItemsPerPage);
            } finally {
              _isNavigating = false;
              complete();
            }
          },
        ));
      }

      final title = offset > 0
          ? 'Playlists (${offset + 1}-${offset + paginatedPlaylists.length} of $totalCount)'
          : 'Playlists ($totalCount)';

      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
          sections: [CPListSection(items: items)],
          systemIcon: 'music.note.list',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Playlists failed: $e');
    }
  }

  Future<void> _showAlbumTracks(String albumId, String albumName) async {
    try {
      // getAlbumTracks usually hits API directly or cache, it doesn't set a global loading state
      // but it's a future so we just await it.
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
    try {
      if (appState.albums == null && !appState.isLoadingAlbums) {
        appState.refreshAlbums();
      }
      
      if (appState.isLoadingAlbums) {
        await _waitFor(() => !appState.isLoadingAlbums);
      }

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
          _isNavigating = true;
          try {
            await _showAlbumTracks(album.id, album.name);
          } finally {
            _isNavigating = false;
            complete();
          }
        },
      )).toList();

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
    try {
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

  Future<void> _showFavorites({int offset = 0}) async {
    try {
      if (appState.favoriteTracks == null && !appState.isLoadingFavorites) {
        appState.refreshFavorites();
      }

      if (appState.isLoadingFavorites) {
        await _waitFor(() => !appState.isLoadingFavorites);
      }

      final allFavorites = appState.favoriteTracks ?? [];

      if (allFavorites.isEmpty) {
        await _showEmptyState('Favorites', 'No favorite tracks yet');
        return;
      }

      // Paginate the list
      final paginatedFavorites = allFavorites.skip(offset).take(_maxItemsPerPage).toList();
      final hasMore = offset + _maxItemsPerPage < allFavorites.length;
      final totalCount = allFavorites.length;

      final items = paginatedFavorites.map((track) => CPListItem(
        text: track.name,
        detailText: '${track.artists.join(', ')} • ${track.album}',
        onPress: (complete, self) {
          // Play track with favorites as queue context
          appState.audioPlayerService.playTrack(
            track,
            queueContext: allFavorites,
            reorderQueue: false,
            // Favorites list is reversed in UI often, but here we just play
          );
          complete();
        },
      )).toList();

      // Add "Load More" item if there are more favorites
      if (hasMore) {
        final remaining = totalCount - (offset + _maxItemsPerPage);
        items.add(CPListItem(
          text: 'Load More...',
          detailText: '$remaining more songs',
          onPress: (complete, self) async {
            _isNavigating = true;
            try {
              await _showFavorites(offset: offset + _maxItemsPerPage);
            } finally {
              _isNavigating = false;
              complete();
            }
          },
        ));
      }

      final title = offset > 0
          ? 'Favorites (${offset + 1}-${offset + paginatedFavorites.length} of $totalCount)'
          : 'Favorites ($totalCount)';

      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
          sections: [CPListSection(items: items)],
          systemIcon: 'heart.fill',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push Favorites failed: $e');
    }
  }

  Future<void> _showRecentlyPlayed({int offset = 0}) async {
    try {
      if (appState.recentlyPlayedTracks == null && !appState.isLoadingRecentlyPlayed) {
        appState.refreshRecent();
      }

      if (appState.isLoadingRecentlyPlayed) {
        await _waitFor(() => !appState.isLoadingRecentlyPlayed);
      }

      final allRecent = appState.recentlyPlayedTracks ?? [];

      if (allRecent.isEmpty) {
        await _showEmptyState('Recently Played', 'No listening history yet');
        return;
      }

      // Paginate the list
      final paginatedRecent = allRecent.skip(offset).take(_maxItemsPerPage).toList();
      final hasMore = offset + _maxItemsPerPage < allRecent.length;
      final totalCount = allRecent.length;

      final items = paginatedRecent.map((track) => CPListItem(
        text: track.name,
        detailText: '${track.artists.join(', ')} • ${track.album}',
        onPress: (complete, self) {
          // Play track with recently played as queue context
          appState.audioPlayerService.playTrack(
            track,
            queueContext: allRecent,
            reorderQueue: false,
          );
          complete();
        },
      )).toList();

      // Add "Load More" item if there are more
      if (hasMore) {
        final remaining = totalCount - (offset + _maxItemsPerPage);
        items.add(CPListItem(
          text: 'Load More...',
          detailText: '$remaining more songs',
          onPress: (complete, self) async {
            _isNavigating = true;
            try {
              await _showRecentlyPlayed(offset: offset + _maxItemsPerPage);
            } finally {
              _isNavigating = false;
              complete();
            }
          },
        ));
      }

      final title = offset > 0
          ? 'Recently Played (${offset + 1}-${offset + paginatedRecent.length} of $totalCount)'
          : 'Recently Played ($totalCount)';

      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
          sections: [CPListSection(items: items)],
          systemIcon: 'clock.fill',
        ),
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push RecentlyPlayed failed: $e');
    }
  }

  Future<void> _showDownloads({int offset = 0}) async {
    try {
      final allDownloads = appState.downloadService.completedDownloads;

      if (allDownloads.isEmpty) {
        await _showEmptyState('Downloads', 'No downloaded music');
        return;
      }

      // Paginate the list
      final paginatedDownloads = allDownloads.skip(offset).take(_maxItemsPerPage).toList();
      final hasMore = offset + _maxItemsPerPage < allDownloads.length;
      final totalCount = allDownloads.length;

      final allTracks = allDownloads.map((d) => d.track).toList();
      final items = paginatedDownloads.map((download) => CPListItem(
        text: download.track.name,
        detailText: '${download.track.artists.join(', ')} • ${download.track.album}',
        onPress: (complete, self) {
          // Play track with all downloads as queue context
          appState.audioPlayerService.playTrack(
            download.track,
            queueContext: allTracks,
            reorderQueue: false,
          );
          complete();
        },
      )).toList();

      // Add "Load More" item if there are more downloads
      if (hasMore) {
        final remaining = totalCount - (offset + _maxItemsPerPage);
        items.add(CPListItem(
          text: 'Load More...',
          detailText: '$remaining more songs',
          onPress: (complete, self) async {
            _isNavigating = true;
            try {
              await _showDownloads(offset: offset + _maxItemsPerPage);
            } finally {
              _isNavigating = false;
              complete();
            }
          },
        ));
      }

      final title = offset > 0
          ? 'Downloads (${offset + 1}-${offset + paginatedDownloads.length} of $totalCount)'
          : 'Downloads ($totalCount)';

      await FlutterCarplay.push(
        template: CPListTemplate(
          title: title,
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
    _refreshDebounceTimer?.cancel();
    _playbackSubscription?.cancel();
    _carplay.removeListenerOnConnectionChange();
    appState.removeListener(_onAppStateChanged);
  }
}