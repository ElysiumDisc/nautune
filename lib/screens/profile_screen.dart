import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart' as hive;
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/jellyfin_user.dart';
import '../providers/session_provider.dart';
import '../services/listenbrainz_service.dart';
import '../services/listening_analytics_service.dart';
import '../services/rewind_service.dart';
import 'rewind_screen.dart';

/// Cache for profile stats to avoid recomputing on every visit
class _ProfileStatsCache {
  static const _boxName = 'profile_stats_cache';
  static const _cacheKey = 'stats';
  static const _cacheValidityMinutes = 5; // Refresh after 5 minutes

  static hive.Box? _box;
  static Map<String, dynamic>? _cachedStats;
  static DateTime? _cacheTime;

  static Future<void> _ensureBox() async {
    _box ??= await hive.Hive.openBox(_boxName);
  }

  static Future<Map<String, dynamic>?> load() async {
    await _ensureBox();

    // Return memory cache if fresh
    if (_cachedStats != null && _cacheTime != null) {
      if (DateTime.now().difference(_cacheTime!).inMinutes < _cacheValidityMinutes) {
        return _cachedStats;
      }
    }

    // Load from disk
    final raw = _box?.get(_cacheKey);
    if (raw == null) return null;

    try {
      final data = raw is String ? jsonDecode(raw) as Map<String, dynamic> : Map<String, dynamic>.from(raw as Map);
      final savedTime = data['_cacheTime'] as int?;

      if (savedTime != null) {
        _cacheTime = DateTime.fromMillisecondsSinceEpoch(savedTime);
        // Check if disk cache is still valid
        if (DateTime.now().difference(_cacheTime!).inMinutes < _cacheValidityMinutes) {
          _cachedStats = data;
          return data;
        }
      }
      return null; // Cache expired
    } catch (e) {
      debugPrint('ProfileStatsCache: Error loading cache: $e');
      return null;
    }
  }

  static Future<void> save(Map<String, dynamic> stats) async {
    await _ensureBox();
    stats['_cacheTime'] = DateTime.now().millisecondsSinceEpoch;
    _cachedStats = stats;
    _cacheTime = DateTime.now();
    await _box?.put(_cacheKey, jsonEncode(stats));
  }

  static bool get isFresh {
    if (_cacheTime == null) return false;
    return DateTime.now().difference(_cacheTime!).inMinutes < _cacheValidityMinutes;
  }
}

/// Computed artist stats from track play history
class _ComputedArtistStats {
  final String name;
  final int playCount;
  final String? id;
  final String? imageTag;

  _ComputedArtistStats({
    required this.name,
    required this.playCount,
    this.id,
    this.imageTag,
  });

  _ComputedArtistStats copyWithImage({String? id, String? imageTag}) {
    return _ComputedArtistStats(
      name: name,
      playCount: playCount,
      id: id ?? this.id,
      imageTag: imageTag ?? this.imageTag,
    );
  }
}

/// Computed album stats from track play history
class _ComputedAlbumStats {
  final String? albumId;
  final String name;
  final String artistName;
  final int playCount;
  final String? imageTag;

  _ComputedAlbumStats({
    this.albumId,
    required this.name,
    required this.artistName,
    required this.playCount,
    this.imageTag,
  });
}

/// Input data for isolate stats computation
class _StatsInput {
  final List<Map<String, dynamic>> tracksJson;

  _StatsInput(this.tracksJson);
}

/// Result from isolate stats computation
class _StatsResult {
  final int totalPlays;
  final double totalHours;
  final Map<String, int> genrePlayCounts;
  final Duration? avgTrackLength;
  final int? longestTrackIndex;
  final int? shortestTrackIndex;
  final int uniqueArtistsCount;
  final int uniqueAlbumsCount;
  final int uniqueTracksCount;
  final double diversityScore;
  final List<Map<String, dynamic>> topArtists; // name, playCount
  final List<Map<String, dynamic>> topAlbums; // albumId, name, artistName, playCount, imageTag

  _StatsResult({
    required this.totalPlays,
    required this.totalHours,
    required this.genrePlayCounts,
    this.avgTrackLength,
    this.longestTrackIndex,
    this.shortestTrackIndex,
    required this.uniqueArtistsCount,
    required this.uniqueAlbumsCount,
    required this.uniqueTracksCount,
    required this.diversityScore,
    required this.topArtists,
    required this.topAlbums,
  });
}

/// Top-level function for isolate computation
_StatsResult _computeStatsIsolate(_StatsInput input) {
  final tracks = input.tracksJson;

  // Calculate totals
  int totalPlays = 0;
  int totalTicks = 0;
  for (final track in tracks) {
    final count = (track['playCount'] as int?) ?? 0;
    totalPlays += count;
    final runtime = track['runTimeTicks'] as int?;
    if (runtime != null) {
      totalTicks += (runtime * count);
    }
  }
  final totalHours = totalTicks / (10000000 * 3600);

  // Calculate genre breakdown
  final genreMap = <String, int>{};
  for (final track in tracks) {
    final genres = (track['genres'] as List<dynamic>?)?.cast<String>() ?? [];
    final playCount = (track['playCount'] as int?) ?? 1;
    for (final genre in genres) {
      genreMap[genre] = (genreMap[genre] ?? 0) + playCount;
    }
  }
  final sortedGenres = genreMap.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topGenres = Map.fromEntries(sortedGenres.take(8));

  // Track length stats
  Duration? avgLength;
  int? longestIndex;
  int? shortestIndex;
  final tracksWithRuntime = <int>[];
  for (int i = 0; i < tracks.length; i++) {
    if (tracks[i]['runTimeTicks'] != null) {
      tracksWithRuntime.add(i);
    }
  }
  if (tracksWithRuntime.isNotEmpty) {
    int totalRuntime = 0;
    int maxRuntime = 0;
    int minRuntime = 0x7FFFFFFFFFFFFFFF;
    for (final idx in tracksWithRuntime) {
      final runtime = tracks[idx]['runTimeTicks'] as int;
      totalRuntime += runtime;
      if (runtime > maxRuntime) {
        maxRuntime = runtime;
        longestIndex = idx;
      }
      if (runtime < minRuntime) {
        minRuntime = runtime;
        shortestIndex = idx;
      }
    }
    avgLength = Duration(microseconds: totalRuntime ~/ tracksWithRuntime.length ~/ 10);
  }

  // Diversity stats
  final uniqueArtists = <String>{};
  final uniqueAlbums = <String>{};
  for (final track in tracks) {
    final artists = (track['artists'] as List<dynamic>?)?.cast<String>() ?? [];
    uniqueArtists.addAll(artists);
    final album = track['album'] as String?;
    if (album != null) {
      uniqueAlbums.add(album);
    }
  }
  final uniqueArtistsCount = uniqueArtists.length;
  final uniqueAlbumsCount = uniqueAlbums.length;
  final uniqueTracksCount = tracks.length;

  double diversity = 0.0;
  if (totalPlays > 0 && uniqueTracksCount > 0) {
    final trackRatio = uniqueTracksCount / totalPlays;
    final artistRatio = uniqueArtistsCount / uniqueTracksCount;
    diversity = ((trackRatio + artistRatio) / 2 * 100).clamp(0, 100);
  }

  // Top artists
  final artistPlayCounts = <String, int>{};
  for (final track in tracks) {
    final playCount = (track['playCount'] as int?) ?? 0;
    final artists = (track['artists'] as List<dynamic>?)?.cast<String>() ?? [];
    for (final artist in artists) {
      artistPlayCounts[artist] = (artistPlayCounts[artist] ?? 0) + playCount;
    }
  }
  final sortedArtists = artistPlayCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topArtists = sortedArtists.take(10).map((e) => {
    'name': e.key,
    'playCount': e.value,
  }).toList();

  // Top albums
  final albumPlayCounts = <String, Map<String, dynamic>>{};
  for (final track in tracks) {
    final albumName = track['album'] as String?;
    if (albumName == null || albumName.isEmpty) continue;
    final playCount = (track['playCount'] as int?) ?? 0;
    final albumId = track['albumId'] as String?;
    final key = albumId ?? albumName;

    if (!albumPlayCounts.containsKey(key)) {
      final artists = (track['artists'] as List<dynamic>?)?.cast<String>() ?? [];
      albumPlayCounts[key] = {
        'albumId': albumId,
        'name': albumName,
        'artistName': artists.isNotEmpty ? artists.first : 'Unknown',
        'imageTag': track['albumPrimaryImageTag'],
        'playCount': 0,
      };
    }
    albumPlayCounts[key]!['playCount'] = (albumPlayCounts[key]!['playCount'] as int) + playCount;
  }
  final sortedAlbums = albumPlayCounts.values.toList()
    ..sort((a, b) => (b['playCount'] as int).compareTo(a['playCount'] as int));
  final topAlbums = sortedAlbums.take(10).toList();

  return _StatsResult(
    totalPlays: totalPlays,
    totalHours: totalHours,
    genrePlayCounts: topGenres,
    avgTrackLength: avgLength,
    longestTrackIndex: longestIndex,
    shortestTrackIndex: shortestIndex,
    uniqueArtistsCount: uniqueArtistsCount,
    uniqueAlbumsCount: uniqueAlbumsCount,
    uniqueTracksCount: uniqueTracksCount,
    diversityScore: diversity,
    topArtists: topArtists,
    topAlbums: topAlbums,
  );
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  JellyfinUser? _user;

  // Stats
  List<JellyfinTrack>? _topTracks;
  List<_ComputedAlbumStats>? _topAlbums;
  List<_ComputedArtistStats>? _topArtists;
  List<JellyfinTrack>? _recentTracks;
  bool _statsLoading = true;

  // Additional Stats
  int _totalPlays = 0;
  double _totalHours = 0.0;
  List<Color>? _paletteColors;

  // Enhanced Stats
  Map<String, int>? _genrePlayCounts;
  Duration? _avgTrackLength;
  JellyfinTrack? _longestTrack;
  JellyfinTrack? _shortestTrack;
  int _uniqueArtistsPlayed = 0;
  int _uniqueAlbumsPlayed = 0;
  int _uniqueTracksPlayed = 0;
  double _diversityScore = 0.0;

  // Local analytics data
  ListeningHeatmap? _heatmap;
  ListeningStreak? _streak;
  PeriodComparison? _weekComparison;
  ListeningMilestones? _milestones;
  RelaxModeStats? _relaxModeStats;
  int? _peakHour;
  Duration? _avgSessionLength;
  double _discoveryRate = 0.0;
  int _unsyncedPlays = 0; // Plays pending server sync

  // Top content tab controller
  int _topContentTab = 0;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadStats();
    _loadLocalAnalytics();
  }

  void _loadLocalAnalytics() {
    final analytics = ListeningAnalyticsService();
    if (!analytics.isInitialized) return;

    setState(() {
      _heatmap = analytics.getListeningHeatmap();
      _streak = analytics.getStreakInfo();
      _weekComparison = analytics.getWeekOverWeekComparison();
      _milestones = analytics.getMilestones();
      _relaxModeStats = analytics.getRelaxModeStats();
      _peakHour = analytics.getPeakListeningHour();
      _avgSessionLength = analytics.getAverageSessionLength();
      _discoveryRate = analytics.getDiscoveryRate();
      _unsyncedPlays = analytics.unsyncedCount;
    });
  }

  Future<void> _loadUserProfile() async {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    try {
      final user = await appState.jellyfinService.getCurrentUser();
      if (mounted) {
        setState(() {
          _user = user;
        });
      }
    } catch (e) {
      debugPrint('Error loading user profile: $e');
    }
  }

  Future<void> _loadStats() async {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final sessionProvider = Provider.of<SessionProvider>(context, listen: false);
    final libraryId = sessionProvider.session?.selectedLibraryId;

    if (libraryId == null) {
      setState(() => _statsLoading = false);
      return;
    }

    // Try to load cached stats first for instant display
    final cachedStats = await _ProfileStatsCache.load();
    if (cachedStats != null && mounted) {
      _applyCachedStats(cachedStats);
      // If cache is still fresh, don't refresh from network
      if (_ProfileStatsCache.isFresh) {
        // Still load recent tracks (they change often)
        _loadRecentTracks(appState, libraryId);
        return;
      }
    }

    // Refresh stats from network
    await _refreshStatsFromNetwork(appState, libraryId);
  }

  void _applyCachedStats(Map<String, dynamic> cached) {
    setState(() {
      _totalPlays = cached['totalPlays'] as int? ?? 0;
      _totalHours = (cached['totalHours'] as num?)?.toDouble() ?? 0.0;
      _uniqueArtistsPlayed = cached['uniqueArtists'] as int? ?? 0;
      _uniqueAlbumsPlayed = cached['uniqueAlbums'] as int? ?? 0;
      _uniqueTracksPlayed = cached['uniqueTracks'] as int? ?? 0;
      _diversityScore = (cached['diversityScore'] as num?)?.toDouble() ?? 0.0;

      final cachedGenres = cached['genrePlayCounts'] as Map<String, dynamic>?;
      if (cachedGenres != null) {
        _genrePlayCounts = cachedGenres.map((k, v) => MapEntry(k, v as int));
      }

      final cachedArtists = cached['topArtists'] as List<dynamic>?;
      if (cachedArtists != null) {
        _topArtists = cachedArtists.map((a) => _ComputedArtistStats(
          name: a['name'] as String,
          playCount: a['playCount'] as int,
          id: a['id'] as String?,
          imageTag: a['imageTag'] as String?,
        )).toList();
      }

      final cachedAlbums = cached['topAlbums'] as List<dynamic>?;
      if (cachedAlbums != null) {
        _topAlbums = cachedAlbums.map((a) => _ComputedAlbumStats(
          albumId: a['albumId'] as String?,
          name: a['name'] as String,
          artistName: a['artistName'] as String,
          playCount: a['playCount'] as int,
          imageTag: a['imageTag'] as String?,
        )).toList();
      }

      final cachedColors = cached['paletteColors'] as List<dynamic>?;
      if (cachedColors != null) {
        _paletteColors = cachedColors.map((c) => Color(c as int)).toList();
      }

      _statsLoading = false;
    });
  }

  Future<void> _loadRecentTracks(NautuneAppState appState, String libraryId) async {
    try {
      final recent = await appState.jellyfinService.getRecentlyPlayedTracks(
        libraryId: libraryId,
        limit: 10,
      );
      if (mounted) {
        setState(() => _recentTracks = recent);
      }
    } catch (e) {
      debugPrint('Error loading recent tracks: $e');
    }
  }

  Future<void> _refreshStatsFromNetwork(NautuneAppState appState, String libraryId) async {
    try {
      // Reduced limit from 10000 to 1000 - still accurate but much faster
      final tracksFuture = appState.jellyfinService.getMostPlayedTracks(libraryId: libraryId, limit: 1000);
      final recentFuture = appState.jellyfinService.getRecentlyPlayedTracks(libraryId: libraryId, limit: 10);
      final results = await Future.wait([tracksFuture, recentFuture]);

      final tracks = results[0];

      // Convert tracks to JSON maps for isolate (tracks are not sendable as-is)
      final tracksJson = tracks.map((t) => {
        'playCount': t.playCount,
        'runTimeTicks': t.runTimeTicks,
        'genres': t.genres,
        'artists': t.artists,
        'album': t.album,
        'albumId': t.albumId,
        'albumPrimaryImageTag': t.albumPrimaryImageTag,
      }).toList();

      // Run heavy computation in isolate
      final statsResult = await compute(_computeStatsIsolate, _StatsInput(tracksJson));

      // Convert results back to proper types
      var computedTopArtists = statsResult.topArtists
          .map((a) => _ComputedArtistStats(
                name: a['name'] as String,
                playCount: a['playCount'] as int,
              ))
          .toList();

      // Look up artist images in parallel (must be on main thread for network)
      try {
        final artistLookups = await Future.wait(
          computedTopArtists.map((artist) =>
            appState.jellyfinService.searchArtists(
              libraryId: libraryId,
              query: artist.name,
            ).then((results) {
              final match = results.where((a) =>
                a.name.toLowerCase() == artist.name.toLowerCase()
              ).firstOrNull;
              if (match != null) {
                return artist.copyWithImage(
                  id: match.id,
                  imageTag: match.primaryImageTag,
                );
              }
              return artist;
            }).catchError((_) => artist),
          ),
        );
        computedTopArtists = artistLookups;
      } catch (e) {
        debugPrint('Error looking up artist images: $e');
      }

      final computedTopAlbums = statsResult.topAlbums
          .map((a) => _ComputedAlbumStats(
                albumId: a['albumId'] as String?,
                name: a['name'] as String,
                artistName: a['artistName'] as String,
                playCount: a['playCount'] as int,
                imageTag: a['imageTag'] as String?,
              ))
          .toList();

      if (mounted) {
        setState(() {
          _topTracks = tracks.take(5).toList();
          _topAlbums = computedTopAlbums;
          _topArtists = computedTopArtists;
          _recentTracks = results[1];
          _totalPlays = statsResult.totalPlays;
          _totalHours = statsResult.totalHours;
          _genrePlayCounts = statsResult.genrePlayCounts;
          _avgTrackLength = statsResult.avgTrackLength;
          _longestTrack = statsResult.longestTrackIndex != null ? tracks[statsResult.longestTrackIndex!] : null;
          _shortestTrack = statsResult.shortestTrackIndex != null ? tracks[statsResult.shortestTrackIndex!] : null;
          _uniqueArtistsPlayed = statsResult.uniqueArtistsCount;
          _uniqueAlbumsPlayed = statsResult.uniqueAlbumsCount;
          _uniqueTracksPlayed = statsResult.uniqueTracksCount;
          _diversityScore = statsResult.diversityScore;
          _statsLoading = false;
        });

        // Extract colors from top track and then save to cache
        if (tracks.isNotEmpty) {
          _extractColors(tracks.first).then((_) => _saveStatsToCache(
            statsResult,
            computedTopArtists,
            computedTopAlbums,
          ));
        } else {
          _saveStatsToCache(statsResult, computedTopArtists, computedTopAlbums);
        }
      }
    } catch (e) {
      debugPrint('Error loading stats: $e');
      if (mounted) {
        setState(() {
          _statsLoading = false;
        });
      }
    }
  }

  Future<void> _saveStatsToCache(
    _StatsResult statsResult,
    List<_ComputedArtistStats> topArtists,
    List<_ComputedAlbumStats> topAlbums,
  ) async {
    final cacheData = <String, dynamic>{
      'totalPlays': statsResult.totalPlays,
      'totalHours': statsResult.totalHours,
      'uniqueArtists': statsResult.uniqueArtistsCount,
      'uniqueAlbums': statsResult.uniqueAlbumsCount,
      'uniqueTracks': statsResult.uniqueTracksCount,
      'diversityScore': statsResult.diversityScore,
      'genrePlayCounts': statsResult.genrePlayCounts,
      'topArtists': topArtists.map((a) => {
        'name': a.name,
        'playCount': a.playCount,
        'id': a.id,
        'imageTag': a.imageTag,
      }).toList(),
      'topAlbums': topAlbums.map((a) => {
        'albumId': a.albumId,
        'name': a.name,
        'artistName': a.artistName,
        'playCount': a.playCount,
        'imageTag': a.imageTag,
      }).toList(),
      // ignore: deprecated_member_use
      'paletteColors': _paletteColors?.map((c) => c.value).toList(),
    };
    await _ProfileStatsCache.save(cacheData);
    debugPrint('ProfileScreen: Stats cached');
  }

  Future<void> _extractColors(JellyfinTrack track) async {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    
    String? imageTag = track.primaryImageTag ?? track.albumPrimaryImageTag ?? track.parentThumbImageTag;
    String? itemId = imageTag != null ? (track.albumId ?? track.id) : null;

    if (itemId == null || imageTag == null) return;

    try {
      final imageUrl = appState.jellyfinService.buildImageUrl(
        itemId: itemId,
        tag: imageTag,
        maxWidth: 100,
      );

      final imageProvider = CachedNetworkImageProvider(
        imageUrl,
        headers: appState.jellyfinService.imageHeaders(),
      );

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();

      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
      });

      imageStream.addListener(listener);
      final image = await completer.future;
      imageStream.removeListener(listener);

      final byteData = await image.toByteData();
      if (byteData == null) return;

      final pixels = byteData.buffer.asUint32List();
      final result = await QuantizerCelebi().quantize(pixels, 128);
      final colorToCount = result.colorToCount;

      final sortedEntries = colorToCount.entries.toList()
        ..sort((a, b) {
          final hctA = Hct.fromInt(a.key);
          final hctB = Hct.fromInt(b.key);
          return (b.value * (hctB.chroma * hctB.chroma)).compareTo(a.value * (hctA.chroma * hctA.chroma));
        });

      final selectedColors = sortedEntries
          .where((e) => Hct.fromInt(e.key).chroma > 5)
          .take(3)
          .map((e) => Color(e.key | 0xFF000000))
          .toList();

      if (mounted && selectedColors.isNotEmpty) {
        setState(() {
          _paletteColors = selectedColors;
        });
      }
    } catch (e) {
      debugPrint('Failed to extract colors for profile: $e');
    }
  }

  String? _getProfileImageUrl() {
    final sessionProvider = Provider.of<SessionProvider>(context, listen: false);
    final session = sessionProvider.session;
    if (session == null) return null;
    return '${session.serverUrl}/Users/${session.credentials.userId}/Images/Primary';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionProvider = Provider.of<SessionProvider>(context);
    final session = sessionProvider.session;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _paletteColors != null && _paletteColors!.length >= 2
                ? [
                    _paletteColors![0].withValues(alpha: 0.8),
                    _paletteColors![1].withValues(alpha: 0.6),
                    theme.colorScheme.surface,
                  ]
                : [
                    theme.colorScheme.surface,
                    theme.colorScheme.surface,
                  ],
          ),
        ),
        child: CustomScrollView(
          slivers: [
            // Profile header with image
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              backgroundColor: Colors.transparent,
              elevation: 0,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _paletteColors != null && _paletteColors!.length >= 2
                          ? [
                              _paletteColors![0].withValues(alpha: 0.9),
                              _paletteColors![1].withValues(alpha: 0.7),
                              Colors.transparent,
                            ]
                          : [
                              theme.colorScheme.primary.withValues(alpha: 0.5),
                              Colors.transparent,
                            ],
                    ),
                  ),
                  child: SafeArea(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 40),
                        // Profile picture
                        _buildProfileAvatar(theme),
                        const SizedBox(height: 16),
                                              // Username
                                              Text(
                                                _user?.name ?? session?.username ?? 'User',
                                                style: GoogleFonts.pacifico(
                                                  fontSize: 28,
                                                  fontWeight: FontWeight.bold,
                                                  color: const Color(0xFFB39DDB),
                                                  shadows: [
                                                    Shadow(
                                                      offset: const Offset(0, 2),
                                                      blurRadius: 4,
                                                      color: Colors.black.withValues(alpha: 0.5),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              // ListenBrainz badge
                                              if (ListenBrainzService().isConfigured)
                                                Padding(
                                                  padding: const EdgeInsets.only(top: 8),
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFFEB743B).withValues(alpha: 0.9),
                                                      borderRadius: BorderRadius.circular(12),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        const Icon(
                                                          Icons.podcasts,
                                                          size: 14,
                                                          color: Colors.white,
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Text(
                                                          'ListenBrainz',
                                                          style: theme.textTheme.labelSmall?.copyWith(
                                                            color: Colors.white,
                                                            fontWeight: FontWeight.w600,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              const SizedBox(height: 4),
                        // Server URL
                        Text(
                          session?.serverUrl ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Stats content
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Hero Ring - Total hours with animated progress
                  _buildHeroRing(theme),
                  const SizedBox(height: 24),

                  // Rewind Banner (if data available)
                  _buildRewindBanner(theme),

                  // 2. Key Metrics - Plays, Artists, Albums (3 cards)
                  _buildKeyMetricsRow(theme),
                  const SizedBox(height: 12),

                  // 2b. Sync Status Banner (only if unsynced plays exist)
                  if (_unsyncedPlays > 0) ...[
                    _buildSyncStatusBanner(theme),
                    const SizedBox(height: 12),
                  ],

                  // 2c. ListenBrainz Stats (if connected)
                  if (ListenBrainzService().isConfigured) ...[
                    _buildListenBrainzStatsRow(theme),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),

                  // 3. Listening Patterns - Peak hour, Avg session, Discovery rate
                  _buildSectionHeader(theme, 'Listening Patterns', Icons.auto_graph),
                  const SizedBox(height: 12),
                  _buildListeningPatterns(theme),
                  const SizedBox(height: 24),

                  // 4. Top Content Tabs - Tracks | Artists | Albums
                  _buildSectionHeader(theme, 'Top Content', Icons.star),
                  const SizedBox(height: 12),
                  _buildTopContentTabs(theme),
                  const SizedBox(height: 24),

                  // 5. Listening Activity - Heatmap, Streaks, Week comparison
                  if (_heatmap != null || _streak != null) ...[
                    _buildSectionHeader(theme, 'Listening Activity', Icons.insights),
                    const SizedBox(height: 12),
                    _buildListeningActivitySection(theme),
                    const SizedBox(height: 24),
                  ],

                  // 6. Achievements - Milestones with enhanced badges
                  if (_milestones != null && _milestones!.all.isNotEmpty) ...[
                    _buildSectionHeader(theme, 'Achievements', Icons.emoji_events),
                    const SizedBox(height: 12),
                    _buildMilestonesSection(theme),
                    const SizedBox(height: 24),
                  ],

                  // 7. Deep Dive - Genre breakdown, detailed insights
                  _buildSectionHeader(theme, 'Deep Dive', Icons.explore),
                  const SizedBox(height: 12),
                  _buildListeningInsights(theme),
                  const SizedBox(height: 16),
                  _buildGenreBreakdown(theme),
                  const SizedBox(height: 16),
                  _buildMonthlyComparison(theme),
                  const SizedBox(height: 16),
                  _buildYearlyComparison(theme),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildProfileAvatar(ThemeData theme) {
    final imageUrl = _getProfileImageUrl();

    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.primary,
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipOval(
        child: imageUrl != null
            ? CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                placeholder: (context, url) => _buildDefaultAvatar(theme),
                errorWidget: (context, url, error) => _buildDefaultAvatar(theme),
              )
            : _buildDefaultAvatar(theme),
      ),
    );
  }

  Widget _buildDefaultAvatar(ThemeData theme) {
    return Container(
      color: theme.colorScheme.primaryContainer,
      child: Icon(
        Icons.person,
        size: 60,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildHeroRing(ThemeData theme) {
    const oceanBlue = Color(0xFF409CFF);
    const deepPurple = Color(0xFF7A3DF1);

    // Progress toward goal (e.g., 100 hours)
    const goalHours = 100.0;
    final progress = (_totalHours / goalHours).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            oceanBlue.withValues(alpha: 0.15),
            deepPurple.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: oceanBlue.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: oceanBlue.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            width: 180,
            height: 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Background ring
                SizedBox(
                  width: 180,
                  height: 180,
                  child: CircularProgressIndicator(
                    value: 1.0,
                    strokeWidth: 12,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                // Progress ring with gradient effect
                SizedBox(
                  width: 180,
                  height: 180,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress),
                    duration: const Duration(milliseconds: 1500),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) {
                      return CircularProgressIndicator(
                        value: value,
                        strokeWidth: 12,
                        strokeCap: StrokeCap.round,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(oceanBlue),
                      );
                    },
                  ),
                ),
                // Inner glow
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        oceanBlue.withValues(alpha: 0.1),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
                // Center content
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: _totalHours),
                      duration: const Duration(milliseconds: 1500),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) {
                        return Text(
                          value.toStringAsFixed(1),
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: oceanBlue,
                            height: 1,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'hours',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Total Listening Time',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${(progress * 100).toStringAsFixed(0)}% toward ${goalHours.toInt()}h goal',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRewindBanner(ThemeData theme) {
    final rewindService = RewindService();
    // Rewind always defaults to previous year (like Spotify Wrapped)
    final previousYear = DateTime.now().year - 1;
    final hasPreviousYearData = rewindService.hasEnoughData(previousYear);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => RewindScreen(initialYear: previousYear),
              ),
            );
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.3),
                  theme.colorScheme.tertiary.withValues(alpha: 0.2),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.replay,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasPreviousYearData
                            ? 'Your $previousYear Rewind is Ready!'
                            : 'Your $previousYear Rewind',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasPreviousYearData
                            ? 'See your top artists, albums & listening personality'
                            : 'Not enough listening data from $previousYear',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyMetricsRow(ThemeData theme) {
    const oceanBlue = Color(0xFF409CFF);
    const emeraldSea = Color(0xFF10B981);
    const goldTreasure = Color(0xFFFFD700);

    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            theme,
            icon: Icons.play_circle_filled,
            label: 'Total Plays',
            value: _totalPlays > 0 ? _formatNumber(_totalPlays) : '-',
            color: oceanBlue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            theme,
            icon: Icons.explore,
            label: 'Artists Explored',
            value: _uniqueArtistsPlayed > 0 ? _formatNumber(_uniqueArtistsPlayed) : '-',
            color: emeraldSea,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            theme,
            icon: Icons.diamond,
            label: 'Albums Collected',
            value: _uniqueAlbumsPlayed > 0 ? _formatNumber(_uniqueAlbumsPlayed) : '-',
            color: goldTreasure,
          ),
        ),
      ],
    );
  }

  Widget _buildListenBrainzStatsRow(ThemeData theme) {
    final listenBrainz = ListenBrainzService();
    final config = listenBrainz.config;
    const listenBrainzOrange = Color(0xFFEB743B);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: listenBrainzOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: listenBrainzOrange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: listenBrainzOrange.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.podcasts,
              color: listenBrainzOrange,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ListenBrainz Scrobbles',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: listenBrainzOrange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  config?.username ?? 'Connected',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatNumber(config?.totalScrobbles ?? 0),
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: listenBrainzOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (listenBrainz.pendingScrobblesCount > 0)
                Text(
                  '+${listenBrainz.pendingScrobblesCount} pending',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSyncStatusBanner(ThemeData theme) {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final isOnline = appState.networkAvailable && !appState.isOfflineMode;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isOnline
            ? const Color(0xFF10B981).withValues(alpha: 0.1)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOnline
              ? const Color(0xFF10B981).withValues(alpha: 0.3)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isOnline ? Icons.cloud_upload : Icons.cloud_off,
            size: 18,
            color: isOnline
                ? const Color(0xFF10B981)
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isOnline
                  ? '$_unsyncedPlays ${_unsyncedPlays == 1 ? 'play' : 'plays'} syncing to server...'
                  : '$_unsyncedPlays ${_unsyncedPlays == 1 ? 'play' : 'plays'} pending sync',
              style: theme.textTheme.bodySmall?.copyWith(
                color: isOnline
                    ? const Color(0xFF10B981)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!isOnline)
            Icon(
              Icons.wifi_off,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.15),
            color.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  Widget _buildListeningPatterns(ThemeData theme) {
    final analytics = ListeningAnalyticsService();
    final discoveryLabel = analytics.getDiscoveryLabel(_discoveryRate);

    String formatSessionLength(Duration? d) {
      if (d == null) return '-';
      final mins = d.inMinutes;
      if (mins < 60) return '${mins}m';
      final hours = d.inHours;
      final remainingMins = mins % 60;
      return remainingMins > 0 ? '${hours}h ${remainingMins}m' : '${hours}h';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildPatternItem(
              theme,
              icon: Icons.schedule,
              label: 'Peak Hour',
              value: _peakHour != null ? _formatHour(_peakHour!) : '-',
              subtext: 'most active',
              color: const Color(0xFF409CFF),
            ),
          ),
          Container(
            width: 1,
            height: 60,
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
          Expanded(
            child: _buildPatternItem(
              theme,
              icon: Icons.timelapse,
              label: 'Avg Session',
              value: formatSessionLength(_avgSessionLength),
              subtext: 'per session',
              color: const Color(0xFF7A3DF1),
            ),
          ),
          Container(
            width: 1,
            height: 60,
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
          Expanded(
            child: _buildPatternItem(
              theme,
              icon: Icons.explore,
              label: 'Discovery',
              value: '${_discoveryRate.toStringAsFixed(0)}%',
              subtext: discoveryLabel,
              color: const Color(0xFF10B981),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatternItem(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required String subtext,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 8),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          subtext,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildTopContentTabs(ThemeData theme) {
    return Column(
      children: [
        // Tab bar
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              Expanded(
                child: _buildTabButton(theme, 'Tracks', 0, Icons.music_note),
              ),
              Expanded(
                child: _buildTabButton(theme, 'Artists', 1, Icons.person),
              ),
              Expanded(
                child: _buildTabButton(theme, 'Albums', 2, Icons.album),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Tab content
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _buildTabContent(theme),
        ),
      ],
    );
  }

  Widget _buildTabButton(ThemeData theme, String label, int index, IconData icon) {
    final isSelected = _topContentTab == index;
    return GestureDetector(
      onTap: () => setState(() => _topContentTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(ThemeData theme) {
    switch (_topContentTab) {
      case 0:
        return _buildTopTracksList(theme);
      case 1:
        return _buildTopArtistsList(theme);
      case 2:
        return _buildTopAlbumsList(theme);
      default:
        return _buildTopTracksList(theme);
    }
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildTopTracksList(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    if (_topTracks == null || _topTracks!.isEmpty) {
      return _buildEmptyCard(theme, 'No play history yet');
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: _topTracks!.asMap().entries.map((entry) {
          final index = entry.key;
          final track = entry.value;
          return ListTile(
            leading: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            title: Text(
              track.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              track.artists.join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: track.playCount != null
                ? Text(
                    '${track.playCount} plays',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTopArtistsList(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    if (_topArtists == null || _topArtists!.isEmpty) {
      return _buildEmptyCard(theme, 'No artist history yet');
    }

    return SizedBox(
      height: 135,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _topArtists!.length,
        itemBuilder: (context, index) {
          final artist = _topArtists![index];
          final session = Provider.of<SessionProvider>(context, listen: false).session;
          final imageUrl = artist.imageTag != null && artist.id != null && session != null
              ? '${session.serverUrl}/Items/${artist.id}/Images/Primary?tag=${artist.imageTag}'
              : null;

          return Padding(
            padding: EdgeInsets.only(right: index < _topArtists!.length - 1 ? 12 : 0),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                    ),
                  ),
                  child: ClipOval(
                    child: imageUrl != null
                        ? CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => _buildArtistPlaceholder(theme, artist.name),
                            errorWidget: (context, url, error) => _buildArtistPlaceholder(theme, artist.name),
                          )
                        : _buildArtistPlaceholder(theme, artist.name),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 80,
                  child: Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (artist.playCount > 0)
                  Text(
                    '${artist.playCount} plays',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildArtistPlaceholder(ThemeData theme, String name) {
    return Container(
      color: theme.colorScheme.primaryContainer,
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildTopAlbumsList(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    if (_topAlbums == null || _topAlbums!.isEmpty) {
      return _buildEmptyCard(theme, 'No album history yet');
    }

    return SizedBox(
      height: 175,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _topAlbums!.length,
        itemBuilder: (context, index) {
          final album = _topAlbums![index];
          final session = Provider.of<SessionProvider>(context, listen: false).session;
          final imageUrl = album.imageTag != null && album.albumId != null && session != null
              ? '${session.serverUrl}/Items/${album.albumId}/Images/Primary?tag=${album.imageTag}'
              : null;

          return Padding(
            padding: EdgeInsets.only(right: index < _topAlbums!.length - 1 ? 12 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageUrl != null
                        ? CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.album,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.album,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.album,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 100,
                  child: Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: Text(
                    album.artistName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (album.playCount > 0)
                  SizedBox(
                    width: 100,
                    child: Text(
                      '${album.playCount} plays',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMonthlyComparison(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    final analytics = ListeningAnalyticsService();
    final comparison = analytics.getMonthOverMonthComparison();

    // Format hours from duration
    String formatHours(Duration d) {
      final hours = d.inMinutes / 60;
      return '${hours.toStringAsFixed(1)}h';
    }

    // Get this month and last month names
    final now = DateTime.now();
    final thisMonthName = _getMonthName(now.month);
    final lastMonthName = _getMonthName(now.month == 1 ? 12 : now.month - 1);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.compare_arrows,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '$thisMonthName vs $lastMonthName',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildComparisonItem(
                  theme,
                  'Plays',
                  comparison.previousPeriodPlays,
                  comparison.currentPeriodPlays,
                  comparison.playsChangePercent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildComparisonItem(
                  theme,
                  'Time',
                  null,
                  null,
                  comparison.timeChangePercent,
                  previousLabel: formatHours(comparison.previousPeriodTime),
                  currentLabel: formatHours(comparison.currentPeriodTime),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildComparisonItem(
                  theme,
                  'Tracks',
                  comparison.previousPeriodUniqueTracks,
                  comparison.currentPeriodUniqueTracks,
                  _calculatePercentChange(
                    comparison.previousPeriodUniqueTracks,
                    comparison.currentPeriodUniqueTracks,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildYearlyComparison(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    final analytics = ListeningAnalyticsService();
    final comparison = analytics.getYearOverYearComparison();

    // Format hours from duration
    String formatHours(Duration d) {
      final hours = d.inMinutes / 60;
      return '${hours.toStringAsFixed(1)}h';
    }

    // Get this year and last year
    final now = DateTime.now();
    final thisYear = now.year.toString();
    final lastYear = (now.year - 1).toString();

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.calendar_today,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '$thisYear vs $lastYear',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildComparisonItem(
                  theme,
                  'Plays',
                  comparison.previousPeriodPlays,
                  comparison.currentPeriodPlays,
                  comparison.playsChangePercent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildComparisonItem(
                  theme,
                  'Time',
                  null,
                  null,
                  comparison.timeChangePercent,
                  previousLabel: formatHours(comparison.previousPeriodTime),
                  currentLabel: formatHours(comparison.currentPeriodTime),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildComparisonItem(
                  theme,
                  'Tracks',
                  comparison.previousPeriodUniqueTracks,
                  comparison.currentPeriodUniqueTracks,
                  _calculatePercentChange(
                    comparison.previousPeriodUniqueTracks,
                    comparison.currentPeriodUniqueTracks,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getMonthName(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }

  double _calculatePercentChange(int previous, int current) {
    if (previous == 0) return current > 0 ? 100 : 0;
    return ((current - previous) / previous) * 100;
  }

  Widget _buildComparisonItem(
    ThemeData theme,
    String label,
    int? previousValue,
    int? currentValue,
    double percentChange, {
    String? previousLabel,
    String? currentLabel,
  }) {
    final isPositive = percentChange >= 0;
    final changeColor = percentChange == 0
        ? theme.colorScheme.onSurfaceVariant
        : (isPositive ? Colors.green : Colors.red);

    final prevDisplay = previousLabel ?? (previousValue?.toString() ?? '0');
    final currDisplay = currentLabel ?? (currentValue?.toString() ?? '0');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              prevDisplay,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.arrow_forward,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              currDisplay,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Icon(
              isPositive ? Icons.arrow_upward : Icons.arrow_downward,
              size: 12,
              color: changeColor,
            ),
            Text(
              '${percentChange.abs().toStringAsFixed(0)}%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: changeColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildRecentlyPlayedList(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    if (_recentTracks == null || _recentTracks!.isEmpty) {
      return _buildEmptyCard(theme, 'No recent plays');
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: _recentTracks!.take(5).map((track) {
          final imageUrl = track.artworkUrl();

          return ListTile(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl != null
                    ? CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            title: Text(
              track.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              track.artists.join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildLoadingCard(ThemeData theme) {
    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: CircularProgressIndicator(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildEmptyCard(ThemeData theme, String message) {
    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildListeningInsights(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    String formatDuration(Duration? d) {
      if (d == null) return '-';
      final mins = d.inMinutes;
      final secs = d.inSeconds % 60;
      return '$mins:${secs.toString().padLeft(2, '0')}';
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildInsightItem(
                  theme,
                  icon: Icons.access_time,
                  label: 'Avg Length',
                  value: formatDuration(_avgTrackLength),
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildInsightItem(
                  theme,
                  icon: Icons.music_note,
                  label: 'Tracks Played',
                  value: _uniqueTracksPlayed > 0 ? _uniqueTracksPlayed.toString() : '-',
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildInsightItem(
                  theme,
                  icon: Icons.auto_awesome,
                  label: 'Diversity',
                  value: _diversityScore > 0 ? '${_diversityScore.toStringAsFixed(0)}%' : '-',
                  color: Colors.amber,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_longestTrack != null) ...[
            _buildTrackInsightRow(
              theme,
              icon: Icons.trending_up,
              label: 'Longest Track',
              track: _longestTrack!,
              color: Colors.orange,
            ),
            const SizedBox(height: 12),
          ],
          if (_shortestTrack != null)
            _buildTrackInsightRow(
              theme,
              icon: Icons.trending_down,
              label: 'Shortest Track',
              track: _shortestTrack!,
              color: Colors.cyan,
            ),
        ],
      ),
    );
  }

  Widget _buildInsightItem(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrackInsightRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required JellyfinTrack track,
    required Color color,
  }) {
    final duration = track.duration;
    final durationStr = duration != null
        ? '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}'
        : '';

    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Text(
          durationStr,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildGenreBreakdown(ThemeData theme) {
    if (_statsLoading) {
      return _buildLoadingCard(theme);
    }

    if (_genrePlayCounts == null || _genrePlayCounts!.isEmpty) {
      return _buildEmptyCard(theme, 'No genre data available');
    }

    final total = _genrePlayCounts!.values.fold(0, (a, b) => a + b);
    final colors = [
      theme.colorScheme.primary,
      theme.colorScheme.secondary,
      theme.colorScheme.tertiary,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
    ];

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: _genrePlayCounts!.entries.toList().asMap().entries.map((entry) {
          final index = entry.key;
          final genre = entry.value.key;
          final count = entry.value.value;
          final percentage = count / total;
          final percentStr = (percentage * 100).toStringAsFixed(1);
          final color = colors[index % colors.length];

          return Padding(
            padding: EdgeInsets.only(bottom: index < _genrePlayCounts!.length - 1 ? 12 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        genre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      '$percentStr%',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: percentage,
                    backgroundColor: color.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildListeningActivitySection(ThemeData theme) {
    return Column(
      children: [
        // Streak and Week Comparison Row
        if (_streak != null || _weekComparison != null)
          Row(
            children: [
              if (_streak != null)
                Expanded(child: _buildStreakCard(theme)),
              if (_streak != null && _weekComparison != null)
                const SizedBox(width: 12),
              if (_weekComparison != null)
                Expanded(child: _buildWeekComparisonCard(theme)),
            ],
          ),

        if ((_streak != null || _weekComparison != null) && _heatmap != null)
          const SizedBox(height: 16),

        // Listening Heatmap
        if (_heatmap != null)
          _buildListeningHeatmap(theme),

        // Relax Mode Stats (only show if discovered)
        if (_relaxModeStats != null && _relaxModeStats!.discovered) ...[
          const SizedBox(height: 16),
          _buildRelaxModeStatsCard(theme),
        ],
      ],
    );
  }

  Widget _buildRelaxModeStatsCard(ThemeData theme) {
    final stats = _relaxModeStats!;
    final totalMinutes = stats.totalTime.inMinutes;
    final hasUsage = stats.rainUsageMs > 0 || stats.thunderUsageMs > 0 || stats.campfireUsageMs > 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.15),
            theme.colorScheme.secondary.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.spa, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Relax Mode',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Total time
          Row(
            children: [
              Icon(Icons.timer_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                totalMinutes >= 60
                    ? '${totalMinutes ~/ 60}h ${totalMinutes % 60}m total'
                    : '${totalMinutes}m total',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          if (hasUsage) ...[
            const SizedBox(height: 12),
            // Sound usage breakdown
            _buildSoundUsageBar(
              theme: theme,
              icon: Icons.water_drop,
              label: 'Rain',
              percent: stats.rainPercent,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 6),
            _buildSoundUsageBar(
              theme: theme,
              icon: Icons.thunderstorm,
              label: 'Thunder',
              percent: stats.thunderPercent,
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(height: 6),
            _buildSoundUsageBar(
              theme: theme,
              icon: Icons.local_fire_department,
              label: 'Campfire',
              percent: stats.campfirePercent,
              color: theme.colorScheme.tertiary,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSoundUsageBar({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required double percent,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent / 100,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(
            '${percent.round()}%',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _buildStreakCard(ThemeData theme) {
    final streak = _streak!;
    final isActive = streak.currentStreak > 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isActive
              ? [
                  Colors.orange.withValues(alpha: 0.2),
                  Colors.deepOrange.withValues(alpha: 0.1),
                ]
              : [
                  theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? Colors.orange.withValues(alpha: 0.3)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isActive ? Icons.local_fire_department : Icons.local_fire_department_outlined,
                color: isActive ? Colors.orange : theme.colorScheme.onSurfaceVariant,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                'Streak',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${streak.currentStreak}',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.orange : theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  streak.currentStreak == 1 ? 'day' : 'days',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (streak.longestStreak > streak.currentStreak) ...[
            const SizedBox(height: 4),
            Text(
              'Best: ${streak.longestStreak} days',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (streak.listenedToday) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    'Today',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWeekComparisonCard(ThemeData theme) {
    final comparison = _weekComparison!;
    final playsChange = comparison.playsChangePercent;
    final isUp = playsChange > 0;
    final isDown = playsChange < 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.compare_arrows,
                color: theme.colorScheme.primary,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                'This Week',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${comparison.currentPeriodPlays}',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'plays',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                isUp ? Icons.trending_up : (isDown ? Icons.trending_down : Icons.trending_flat),
                color: isUp ? Colors.green : (isDown ? Colors.red : theme.colorScheme.onSurfaceVariant),
                size: 16,
              ),
              const SizedBox(width: 4),
              Text(
                isUp
                    ? '+${playsChange.toStringAsFixed(0)}%'
                    : '${playsChange.toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isUp ? Colors.green : (isDown ? Colors.red : theme.colorScheme.onSurfaceVariant),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                ' vs last week',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildListeningHeatmap(ThemeData theme) {
    final heatmap = _heatmap!;
    final dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.grid_on, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'When You Listen',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              if (_peakHour != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Peak: ${_formatHour(_peakHour!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Hour labels (0, 6, 12, 18)
          Row(
            children: [
              const SizedBox(width: 24), // Space for day labels
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('12am', style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    )),
                    Text('6am', style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    )),
                    Text('12pm', style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    )),
                    Text('6pm', style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    )),
                    Text('11pm', style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    )),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Heatmap grid
          ...List.generate(7, (dayIndex) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Text(
                      dayLabels[dayIndex],
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Row(
                      children: List.generate(24, (hourIndex) {
                        final intensity = heatmap.getIntensity(dayIndex, hourIndex);
                        final count = heatmap.getCount(dayIndex, hourIndex);

                        return Expanded(
                          child: Tooltip(
                            message: '$count plays',
                            child: Container(
                              height: 16,
                              margin: const EdgeInsets.symmetric(horizontal: 0.5),
                              decoration: BoxDecoration(
                                color: intensity > 0
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.2 + (intensity * 0.8),
                                      )
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 12),

          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Less',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
              const SizedBox(width: 8),
              ...List.generate(5, (index) {
                final intensity = index / 4;
                return Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: intensity > 0
                        ? theme.colorScheme.primary.withValues(
                            alpha: 0.2 + (intensity * 0.8),
                          )
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
              const SizedBox(width: 8),
              Text(
                'More',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatHour(int hour) {
    if (hour == 0) return '12am';
    if (hour == 12) return '12pm';
    if (hour < 12) return '${hour}am';
    return '${hour - 12}pm';
  }

  Widget _buildMilestonesSection(ThemeData theme) {
    final milestones = _milestones!;
    final unlocked = milestones.unlocked;
    final nextToUnlock = milestones.nextToUnlock;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress summary
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.amber.withValues(alpha: 0.2),
                Colors.orange.withValues(alpha: 0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.amber.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${milestones.unlockedCount}',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.amber,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${milestones.unlockedCount} of ${milestones.totalCount} Unlocked',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: milestones.unlockedCount / milestones.totalCount,
                        backgroundColor: Colors.amber.withValues(alpha: 0.2),
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
                        minHeight: 8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Next milestone to unlock
        if (nextToUnlock != null) ...[
          const SizedBox(height: 16),
          _buildNextMilestoneCard(theme, nextToUnlock),
        ],

        // Unlocked badges grid
        if (unlocked.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Earned Badges',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: unlocked.map((m) => _buildMilestoneBadge(theme, m)).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildNextMilestoneCard(ThemeData theme, ListeningMilestone milestone) {
    final icon = _getMilestoneIcon(milestone.iconType);
    final color = _getMilestoneColor(milestone.iconType);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color.withValues(alpha: 0.5), size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Next: ',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      milestone.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  milestone.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: milestone.progress,
                          backgroundColor: color.withValues(alpha: 0.1),
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${milestone.currentValue}/${milestone.targetValue}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMilestoneBadge(ThemeData theme, ListeningMilestone milestone) {
    final icon = _getMilestoneIcon(milestone.iconType);
    final color = _getMilestoneColor(milestone.iconType);

    // Determine tier based on milestone target value
    final tier = _getMilestoneTier(milestone);
    final tierBorderColor = _getTierBorderColor(tier);

    return Tooltip(
      message: milestone.description,
      child: Container(
        width: 80,
        height: 80,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.25),
              color.withValues(alpha: 0.1),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: tierBorderColor,
            width: 2,
          ),
          boxShadow: [
            // Outer glow
            BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: 12,
              spreadRadius: 1,
            ),
            // Inner highlight
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(-2, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon with shine effect
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        color.withValues(alpha: 0.3),
                        color.withValues(alpha: 0.1),
                      ],
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                // Shine highlight
                Positioned(
                  top: 4,
                  left: 8,
                  child: Container(
                    width: 8,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              milestone.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getMilestoneTier(ListeningMilestone milestone) {
    // Determine tier based on milestone ID pattern
    final id = milestone.id;
    if (id.contains('10000') || id.contains('500') && id.contains('hours') ||
        id.contains('365') || id.contains('1000') && !id.contains('10000')) {
      return 'gold';
    } else if (id.contains('5000') || id.contains('250') || id.contains('100') ||
        id.contains('60') || id.contains('200')) {
      return 'silver';
    }
    return 'bronze';
  }

  Color _getTierBorderColor(String tier) {
    switch (tier) {
      case 'gold':
        return const Color(0xFFFFD700); // Gold
      case 'silver':
        return const Color(0xFFC0C0C0); // Silver
      default:
        return const Color(0xFFCD7F32); // Bronze
    }
  }

  IconData _getMilestoneIcon(IconType type) {
    switch (type) {
      case IconType.plays:
        return Icons.sailing; // Nautical - sailing/voyage
      case IconType.hours:
        return Icons.waves; // Ocean depths
      case IconType.streak:
        return Icons.air; // Trade winds
      case IconType.artists:
        return Icons.explore; // Explorer/compass
      case IconType.albums:
        return Icons.diamond; // Treasure
      case IconType.tracks:
        return Icons.auto_awesome; // Pearls/shells sparkle
      case IconType.genres:
        return Icons.navigation; // Navigation/compass for genre exploration
      case IconType.special:
        return Icons.nightlight_round; // Moon/night for time-based milestones
    }
  }

  Color _getMilestoneColor(IconType type) {
    switch (type) {
      case IconType.plays:
        return const Color(0xFF409CFF); // Ocean blue (Nautune theme)
      case IconType.hours:
        return const Color(0xFF7A3DF1); // Deep purple (Nautune theme)
      case IconType.streak:
        return Colors.orange; // Warm sunset
      case IconType.artists:
        return const Color(0xFF10B981); // Emerald sea
      case IconType.albums:
        return const Color(0xFFFFD700); // Gold treasure
      case IconType.tracks:
        return const Color(0xFFEC4899); // Pearl pink
      case IconType.genres:
        return const Color(0xFF06B6D4); // Cyan - navigation/compass color
      case IconType.special:
        return const Color(0xFF8B5CF6); // Violet - mystical night creatures
    }
  }
}
