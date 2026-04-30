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
  int _syncGeneration = 0;

  /// Cancel any in-flight sync operations. Future syncs still allowed.
  void cancelSync() {
    _syncGeneration++;
    debugPrint('Bootstrap: Sync cancelled (generation $_syncGeneration)');
  }

  Future<BootstrapSnapshot> loadCachedSnapshot({
    required JellyfinSession session,
    String? libraryIdOverride,
  }) async {
    final sessionKey = _cacheService.cacheKeyForSession(session);
    final selectedLibraryId = libraryIdOverride ?? session.selectedLibraryId;

    // Parallelize all cache reads
    final results = await Future.wait([
      _cacheService.readLibraries(sessionKey),
      _cacheService.readPlaylists(sessionKey),
      if (selectedLibraryId != null) ...[
        _cacheService.readAlbums(sessionKey, libraryId: selectedLibraryId),
        _cacheService.readArtists(sessionKey, libraryId: selectedLibraryId),
        _cacheService.readRecentTracks(sessionKey, libraryId: selectedLibraryId),
        _cacheService.readRecentlyAddedAlbums(sessionKey, libraryId: selectedLibraryId),
      ] else ...[
        Future.value(null),
        Future.value(null),
        Future.value(null),
        Future.value(null),
      ],
    ]);

    return BootstrapSnapshot(
      libraries: results[0] as List<JellyfinLibrary>?,
      playlists: results[1] as List<JellyfinPlaylist>?,
      albums: results[2] as List<JellyfinAlbum>?,
      artists: results[3] as List<JellyfinArtist>?,
      recentTracks: results[4] as List<JellyfinTrack>?,
      recentlyAddedAlbums: results[5] as List<JellyfinAlbum>?,
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
    final generation = _syncGeneration;
    unawaited(() async {
      try {
        final result = await _withRetry(fetch);
        // Abort if sync was cancelled while we were fetching
        if (_syncGeneration != generation) return;
        await persist(result);
        if (_syncGeneration != generation) return;
        onNetworkReachable?.call();
        onUpdate?.call(result);
      } catch (error, stackTrace) {
        if (_syncGeneration != generation) return;
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
