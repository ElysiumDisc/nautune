import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_exceptions.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_session.dart';
import '../jellyfin/jellyfin_track.dart';
import 'local_cache_service.dart';

class BootstrapSnapshot {
  const BootstrapSnapshot({
    this.libraries,
    this.albums,
    this.artists,
    this.playlists,
    this.recentTracks,
    this.recentlyAddedAlbums,
  });

  final List<JellyfinLibrary>? libraries;
  final List<JellyfinAlbum>? albums;
  final List<JellyfinArtist>? artists;
  final List<JellyfinPlaylist>? playlists;
  final List<JellyfinTrack>? recentTracks;
  final List<JellyfinAlbum>? recentlyAddedAlbums;

  bool get hasAnyData {
    return [
      libraries,
      albums,
      artists,
      playlists,
      recentTracks,
      recentlyAddedAlbums,
    ].any((items) => (items?.isNotEmpty ?? false));
  }
}

/// Loads cached data synchronously and refreshes Jellyfin collections in the background.
class BootstrapService {
  BootstrapService({
    required LocalCacheService cacheService,
    required JellyfinService jellyfinService,
    Duration syncTimeout = const Duration(seconds: 8),
    int maxRetries = 2,
  })  : _cacheService = cacheService,
        _jellyfinService = jellyfinService,
        _syncTimeout = syncTimeout,
        _maxRetries = maxRetries;

  final LocalCacheService _cacheService;
  final JellyfinService _jellyfinService;
  final Duration _syncTimeout;
  final int _maxRetries;

  Future<BootstrapSnapshot> loadCachedSnapshot({
    required JellyfinSession session,
    String? libraryIdOverride,
  }) async {
    final sessionKey = _cacheService.cacheKeyForSession(session);
    final selectedLibraryId = libraryIdOverride ?? session.selectedLibraryId;

    final libraries = await _cacheService.readLibraries(sessionKey);
    final playlists = await _cacheService.readPlaylists(sessionKey);
    final albums = selectedLibraryId != null
        ? await _cacheService.readAlbums(sessionKey, libraryId: selectedLibraryId)
        : null;
    final artists = selectedLibraryId != null
        ? await _cacheService.readArtists(sessionKey, libraryId: selectedLibraryId)
        : null;
    final recentTracks = selectedLibraryId != null
        ? await _cacheService.readRecentTracks(sessionKey, libraryId: selectedLibraryId)
        : null;
    final recentlyAdded = selectedLibraryId != null
        ? await _cacheService.readRecentlyAddedAlbums(sessionKey, libraryId: selectedLibraryId)
        : null;

    return BootstrapSnapshot(
      libraries: libraries,
      playlists: playlists,
      albums: albums,
      artists: artists,
      recentTracks: recentTracks,
      recentlyAddedAlbums: recentlyAdded,
    );
  }

  void scheduleSync({
    required JellyfinSession session,
    String? libraryIdOverride,
    ValueChanged<List<JellyfinLibrary>>? onLibraries,
    ValueChanged<List<JellyfinPlaylist>>? onPlaylists,
    ValueChanged<List<JellyfinAlbum>>? onAlbums,
    ValueChanged<List<JellyfinArtist>>? onArtists,
    ValueChanged<List<JellyfinTrack>>? onRecent,
    ValueChanged<List<JellyfinAlbum>>? onRecentlyAdded,
    VoidCallback? onNetworkReachable,
    ValueChanged<Object>? onNetworkLost,
    VoidCallback? onUnauthorized,
  }) {
    final sessionKey = _cacheService.cacheKeyForSession(session);
    final selectedLibraryId = libraryIdOverride ?? session.selectedLibraryId;

    _runSync<JellyfinLibrary>(
      label: 'libraries',
      fetch: () => _jellyfinService.loadLibraries(),
      persist: (data) => _cacheService.saveLibraries(sessionKey, data),
      onUpdate: onLibraries,
      onNetworkReachable: onNetworkReachable,
      onNetworkLost: onNetworkLost,
      onUnauthorized: onUnauthorized,
    );

    _runSync<JellyfinPlaylist>(
      label: 'playlists',
      fetch: () => _jellyfinService.loadPlaylists(forceRefresh: true),
      persist: (data) => _cacheService.savePlaylists(sessionKey, data),
      onUpdate: onPlaylists,
      onNetworkReachable: onNetworkReachable,
      onNetworkLost: onNetworkLost,
      onUnauthorized: onUnauthorized,
    );

    if (selectedLibraryId == null) {
      return;
    }

    _runSync<JellyfinAlbum>(
      label: 'albums',
      fetch: () => _jellyfinService.loadAlbums(
        libraryId: selectedLibraryId,
        forceRefresh: true,
        startIndex: 0,
        limit: 50,
      ),
      persist: (data) => _cacheService.saveAlbums(
        sessionKey,
        libraryId: selectedLibraryId,
        data: data,
      ),
      onUpdate: onAlbums,
      onNetworkReachable: onNetworkReachable,
      onNetworkLost: onNetworkLost,
      onUnauthorized: onUnauthorized,
    );

    _runSync<JellyfinArtist>(
      label: 'artists',
      fetch: () => _jellyfinService.loadArtists(
        libraryId: selectedLibraryId,
        forceRefresh: true,
        startIndex: 0,
        limit: 50,
      ),
      persist: (data) => _cacheService.saveArtists(
        sessionKey,
        libraryId: selectedLibraryId,
        data: data,
      ),
      onUpdate: onArtists,
      onNetworkReachable: onNetworkReachable,
      onNetworkLost: onNetworkLost,
      onUnauthorized: onUnauthorized,
    );

    _runSync<JellyfinTrack>(
      label: 'continue-listening',
      fetch: () => _jellyfinService.loadRecentTracks(
        libraryId: selectedLibraryId,
        forceRefresh: true,
        limit: 50,
      ),
      persist: (data) => _cacheService.saveRecentTracks(
        sessionKey,
        libraryId: selectedLibraryId,
        data: data,
      ),
      onUpdate: onRecent,
      onNetworkReachable: onNetworkReachable,
      onNetworkLost: onNetworkLost,
      onUnauthorized: onUnauthorized,
    );

    _runSync<JellyfinAlbum>(
      label: 'recently-added',
      fetch: () => _jellyfinService.loadRecentlyAddedAlbums(
        libraryId: selectedLibraryId,
        forceRefresh: true,
        limit: 20,
      ),
      persist: (data) => _cacheService.saveRecentlyAddedAlbums(
        sessionKey,
        libraryId: selectedLibraryId,
        data: data,
      ),
      onUpdate: onRecentlyAdded,
      onNetworkReachable: onNetworkReachable,
      onNetworkLost: onNetworkLost,
      onUnauthorized: onUnauthorized,
    );
  }

  void _runSync<T>({
    required String label,
    required Future<List<T>> Function() fetch,
    required Future<void> Function(List<T>) persist,
    required ValueChanged<List<T>>? onUpdate,
    VoidCallback? onNetworkReachable,
    ValueChanged<Object>? onNetworkLost,
    VoidCallback? onUnauthorized,
  }) {
    unawaited(() async {
      try {
        final result = await _withRetry(fetch);
        await persist(result);
        onNetworkReachable?.call();
        onUpdate?.call(result);
      } catch (error, stackTrace) {
        if (_isUnauthorized(error)) {
          debugPrint('Bootstrap sync for $label unauthorized: $error');
          onUnauthorized?.call();
          return;
        }
        debugPrint('Bootstrap sync for $label failed: $error');
        onNetworkLost?.call(error);
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'bootstrap_service',
            context: ErrorDescription('syncing $label'),
          ),
        );
      }
    }());
  }

  Future<List<T>> _withRetry<T>(Future<List<T>> Function() fetch) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await fetch().timeout(_syncTimeout);
      } catch (error) {
        lastError = error;
        if (attempt < _maxRetries) {
          await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
        }
      }
    }
    throw lastError ?? StateError('Unknown bootstrap failure');
  }

  bool _isUnauthorized(Object error) {
    if (error is JellyfinAuthException) {
      return true;
    }
    if (error is JellyfinRequestException) {
      return error.message.contains('401');
    }
    return false;
  }
}
