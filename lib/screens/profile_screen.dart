import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/jellyfin_user.dart';
import '../jellyfin/server_uri.dart';
import '../providers/session_provider.dart';
import '../services/listenbrainz_service.dart';
import '../services/listening_analytics_service.dart';
import '../services/profile_stats_cache.dart';
import '../theme/nautune_theme.dart';
import '../utils/artwork_colors.dart';
import '../widgets/jellyfin_image.dart';

/// Display fields of a track shown on the Profile. Unlike
/// `JellyfinTrack.toStorageJson()` this carries no server URL or token, so it
/// is safe to cache on disk.
class _TrackSummary {
  final String id;
  final String name;
  final List<String> artists;
  final int? playCount;
  final int? runTimeTicks;
  final String? qualityInfo;
  final String? imageItemId;
  final String? imageTag;

  const _TrackSummary({
    required this.id,
    required this.name,
    required this.artists,
    this.playCount,
    this.runTimeTicks,
    this.qualityInfo,
    this.imageItemId,
    this.imageTag,
  });

  factory _TrackSummary.fromTrack(JellyfinTrack track) {
    final imageTag = track.primaryImageTag ??
        track.albumPrimaryImageTag ??
        track.parentThumbImageTag;
    return _TrackSummary(
      id: track.id,
      name: track.name,
      artists: List<String>.from(track.artists),
      playCount: track.playCount,
      runTimeTicks: track.runTimeTicks,
      qualityInfo: track.audioQualityInfo,
      imageItemId: imageTag != null ? (track.albumId ?? track.id) : null,
      imageTag: imageTag,
    );
  }

  factory _TrackSummary.fromJson(Map<String, dynamic> json) => _TrackSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        artists: (json['artists'] as List<dynamic>?)?.cast<String>() ?? const [],
        playCount: json['playCount'] as int?,
        runTimeTicks: json['runTimeTicks'] as int?,
        qualityInfo: json['qualityInfo'] as String?,
        imageItemId: json['imageItemId'] as String?,
        imageTag: json['imageTag'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'artists': artists,
        'playCount': playCount,
        'runTimeTicks': runTimeTicks,
        'qualityInfo': qualityInfo,
        'imageItemId': imageItemId,
        'imageTag': imageTag,
      };

  Duration? get duration =>
      runTimeTicks == null ? null : Duration(microseconds: runTimeTicks! ~/ 10);
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
  final Map<String, int> codecCounts;
  final String? mostCommonFormat;
  final int? highestQualityTrackIndex;

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
    required this.codecCounts,
    this.mostCommonFormat,
    this.highestQualityTrackIndex,
  });
}

/// Audio quality score for a track (higher = better).
int _qualityScore(Map<String, dynamic> track) {
  int score = 0;
  final bitDepth = track['bitDepth'] as int?;
  final sampleRate = track['sampleRate'] as int?;
  final bitrate = track['bitrate'] as int?;
  // Bit depth scoring: 16-bit = 160, 24-bit = 240, 32-bit = 320
  if (bitDepth != null) score += bitDepth * 10;
  // Sample rate scoring (kHz * 2)
  if (sampleRate != null) score += (sampleRate / 1000).round() * 2;
  // Bitrate scoring (kbps / 10)
  if (bitrate != null) score += bitrate ~/ 10000;
  // Lossless bonus
  final codec = (track['codec'] as String?)?.toLowerCase() ?? '';
  if (codec == 'flac' || codec == 'alac' || codec == 'wav') score += 100;
  return score;
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
  // Genres with no plays would make every percentage NaN.
  genreMap.removeWhere((_, count) => count <= 0);
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

  // Audiophile stats: codec breakdown and highest quality track
  final codecCounts = <String, int>{};
  int? highestQualityIndex;
  int highestQualityScore = 0;
  for (int i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final codec = (track['codec'] as String?) ??
        (track['container'] as String?) ??
        'Unknown';
    codecCounts[codec] = (codecCounts[codec] ?? 0) + 1;
    final score = _qualityScore(track);
    if (score > highestQualityScore) {
      highestQualityScore = score;
      highestQualityIndex = i;
    }
  }
  String? mostCommonFormat;
  int mostCommonCount = 0;
  codecCounts.forEach((codec, count) {
    if (count > mostCommonCount) {
      mostCommonCount = count;
      mostCommonFormat = codec;
    }
  });

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
    codecCounts: codecCounts,
    mostCommonFormat: mostCommonFormat,
    highestQualityTrackIndex: highestQualityIndex,
  );
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  JellyfinUser? _user;

  /// Dashboard layout mode. `true` = new bento overview grid (default);
  /// `false` = legacy long-scroll layout with every section expanded.
  /// Toggled by the AppBar action. Preserves the existing sections so any
  /// deep-link/tap handler into the full view still works when detailed
  /// drill-down is needed.
  bool _bentoMode = true;

  // Stats
  List<_TrackSummary>? _topTracks;
  List<_ComputedAlbumStats>? _topAlbums;
  List<_ComputedArtistStats>? _topArtists;
  bool _statsLoading = true;

  // Additional Stats
  int _totalPlays = 0;
  double _totalHours = 0.0;
  List<Color>? _paletteColors;

  // Enhanced Stats
  Map<String, int>? _genrePlayCounts;
  Duration? _avgTrackLength;
  _TrackSummary? _longestTrack;
  _TrackSummary? _shortestTrack;
  int _uniqueArtistsPlayed = 0;
  int _uniqueAlbumsPlayed = 0;
  int _uniqueTracksPlayed = 0;
  double _diversityScore = 0.0;

  // Local analytics data
  ListeningHeatmap? _heatmap;
  ListeningStreak? _streak;
  PeriodComparison? _weekComparison;
  PeriodComparison? _monthComparison;
  PeriodComparison? _yearComparison;
  List<int>? _dailyPlayCounts;
  int? _peakHour;
  int? _peakDay;
  int _marathonSessions = 0;
  Duration? _avgSessionLength;
  double _discoveryRate = 0.0;
  int _unsyncedPlays = 0; // Plays pending server sync

  // Played-content overview counts ("Your Musical Ocean")
  int _libraryTracks = 0;
  int _libraryAlbums = 0;
  int _libraryArtists = 0;
  int _favoritesCount = 0;

  // Audiophile stats
  Map<String, int>? _codecBreakdown;
  _TrackSummary? _highestQualityTrack;
  String? _mostCommonFormat;

  // On This Day events
  List<PlayEvent>? _onThisDayEvents;
  bool _onThisDayExpanded = false;

  // Top content tab controller
  int _topContentTab = 0;

  // Local analytics service (listening stats refresh)
  ListeningAnalyticsService? _analyticsService;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadStats();
    _loadLocalAnalytics();
    _loadLibraryOverview();
  }

  @override
  void dispose() {
    _analyticsService?.removeListener(_onLocalAnalyticsChanged);
    super.dispose();
  }

  void _loadLocalAnalytics() {
    _analyticsService = ListeningAnalyticsService();
    if (!_analyticsService!.isInitialized) return;

    _analyticsService!.addListener(_onLocalAnalyticsChanged);
    // Load initial state
    _onLocalAnalyticsChanged();
  }

  /// Recomputes every local-analytics aggregate once, so `build()` only
  /// reads state and never rescans the play history.
  void _onLocalAnalyticsChanged() {
    if (!mounted || _analyticsService == null) return;
    final analytics = _analyticsService!;
    if (!analytics.isInitialized) return;

    setState(() {
      _heatmap = analytics.getListeningHeatmap();
      _streak = analytics.getStreakInfo();
      _weekComparison = analytics.getWeekOverWeekComparison();
      _monthComparison = analytics.getMonthOverMonthComparison();
      _yearComparison = analytics.getYearOverYearComparison();
      _dailyPlayCounts = analytics.getDailyPlayCounts(days: 28);
      _peakHour = analytics.getPeakListeningHour();
      _peakDay = analytics.getPeakDayOfWeek();
      _marathonSessions = analytics.getMarathonSessionCount();
      _avgSessionLength = analytics.getAverageSessionLength();
      _discoveryRate = analytics.getDiscoveryRate();
      _unsyncedPlays = analytics.unsyncedCount;
      _onThisDayEvents = analytics.getOnThisDayEvents();
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

  Future<void> _loadLibraryOverview() async {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final sessionProvider = Provider.of<SessionProvider>(context, listen: false);
    final libraryId = sessionProvider.session?.selectedLibraryId;

    if (libraryId == null) return;

    try {
      // Favorites count: two count-only queries in parallel (fetching every
      // favorite track and album just to count them was slow).
      final counts = await Future.wait([
        appState.jellyfinService.countFavorites(itemTypes: 'Audio'),
        appState.jellyfinService.countFavorites(itemTypes: 'MusicAlbum'),
      ]);

      if (mounted) {
        setState(() {
          _favoritesCount = counts[0] + counts[1];
        });
      }
    } catch (e) {
      debugPrint('Error loading library overview: $e');
    }
  }

  Future<void> _loadStats() async {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final sessionProvider = Provider.of<SessionProvider>(context, listen: false);
    final session = sessionProvider.session;
    final libraryId = session?.selectedLibraryId;

    if (session == null || libraryId == null) {
      setState(() => _statsLoading = false);
      return;
    }

    // Stats are cached per user, server and library so another account or
    // library never sees them.
    final scope = ProfileStatsCache.scopeFor(
      userId: session.credentials.userId,
      serverUrl: session.serverUrl,
      libraryId: libraryId,
    );

    try {
      // Show fresh cached stats instantly and skip the network.
      // Timeout prevents Hive box corruption/lock from hanging forever
      final cachedStats =
          await ProfileStatsCache.load(scope).timeout(const Duration(seconds: 5));
      if (cachedStats != null && mounted && _applyCachedStats(cachedStats)) {
        return;
      }

      // Refresh stats from network
      await _refreshStatsFromNetwork(appState, libraryId, scope);
    } catch (e) {
      debugPrint('Error loading stats: $e');
    } finally {
      if (mounted && _statsLoading) {
        setState(() => _statsLoading = false);
      }
    }
  }

  /// Applies cached stats. Returns false (and changes nothing) if the entry
  /// can't be read, so the caller refreshes from the server instead.
  bool _applyCachedStats(Map<String, dynamic> cached) {
    try {
      List<Map<String, dynamic>> maps(Object? value) => (value as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [];
      _TrackSummary? summary(Object? value) => value == null
          ? null
          : _TrackSummary.fromJson(Map<String, dynamic>.from(value as Map));
      Map<String, int>? counts(Object? value) => (value as Map<dynamic, dynamic>?)
          ?.map((k, v) => MapEntry(k as String, v as int));

      final topArtists = maps(cached['topArtists'])
          .map((a) => _ComputedArtistStats(
                name: a['name'] as String,
                playCount: a['playCount'] as int,
                id: a['id'] as String?,
                imageTag: a['imageTag'] as String?,
              ))
          .toList();
      final topAlbums = maps(cached['topAlbums'])
          .map((a) => _ComputedAlbumStats(
                albumId: a['albumId'] as String?,
                name: a['name'] as String,
                artistName: a['artistName'] as String,
                playCount: a['playCount'] as int,
                imageTag: a['imageTag'] as String?,
              ))
          .toList();
      final topTracks = maps(cached['topTracks']).map(_TrackSummary.fromJson).toList();
      final paletteColors = (cached['paletteColors'] as List<dynamic>?)
          ?.map((c) => Color(c as int))
          .toList();
      final avgMs = cached['avgTrackLengthMs'] as int?;
      final uniqueArtists = cached['uniqueArtists'] as int? ?? 0;
      final uniqueAlbums = cached['uniqueAlbums'] as int? ?? 0;
      final uniqueTracks = cached['uniqueTracks'] as int? ?? 0;

      setState(() {
        _totalPlays = cached['totalPlays'] as int? ?? 0;
        _totalHours = (cached['totalHours'] as num?)?.toDouble() ?? 0.0;
        _uniqueArtistsPlayed = uniqueArtists;
        _uniqueAlbumsPlayed = uniqueAlbums;
        _uniqueTracksPlayed = uniqueTracks;
        _libraryTracks = uniqueTracks;
        _libraryAlbums = uniqueAlbums;
        _libraryArtists = uniqueArtists;
        _diversityScore = (cached['diversityScore'] as num?)?.toDouble() ?? 0.0;
        _genrePlayCounts = counts(cached['genrePlayCounts']);
        _topArtists = topArtists;
        _topAlbums = topAlbums;
        _topTracks = topTracks;
        _paletteColors = paletteColors;
        _avgTrackLength = avgMs == null ? null : Duration(milliseconds: avgMs);
        _longestTrack = summary(cached['longestTrack']);
        _shortestTrack = summary(cached['shortestTrack']);
        _highestQualityTrack = summary(cached['highestQualityTrack']);
        _codecBreakdown = counts(cached['codecBreakdown']);
        _mostCommonFormat = cached['mostCommonFormat'] as String?;
        _statsLoading = false;
      });
      return true;
    } catch (e) {
      debugPrint('ProfileScreen: Ignoring unreadable stats cache: $e');
      return false;
    }
  }

  Future<void> _refreshStatsFromNetwork(
    NautuneAppState appState,
    String libraryId,
    String cacheScope,
  ) async {
    try {
      // Fetch ALL played tracks via pagination for accurate stats
      final tracks = await appState.jellyfinService.getAllPlayedTracks(libraryId: libraryId);

      // Convert tracks to JSON maps for isolate (tracks are not sendable as-is)
      final tracksJson = tracks.map((t) => {
        'playCount': t.playCount,
        'runTimeTicks': t.runTimeTicks,
        'genres': t.genres,
        'artists': t.artists,
        'album': t.album,
        'albumId': t.albumId,
        'albumPrimaryImageTag': t.albumPrimaryImageTag,
        'codec': t.codec,
        'container': t.container,
        'bitDepth': t.bitDepth,
        'sampleRate': t.sampleRate,
        'bitrate': t.bitrate,
      }).toList();

      // Run heavy computation (aggregates, codec breakdown, quality scoring)
      // in an isolate
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

      _TrackSummary? summaryAt(int? index) =>
          index == null ? null : _TrackSummary.fromTrack(tracks[index]);

      // Use actual listening time from local analytics instead of
      // server-calculated trackDuration × playCount (which is inflated).
      // With no local history (new device, reinstall) fall back to the server
      // estimate rather than showing 0 hours.
      final actualListeningTime = _analyticsService?.getTotalListeningTime();
      final actualHours = actualListeningTime != null && actualListeningTime > Duration.zero
          ? actualListeningTime.inSeconds / 3600.0
          : statsResult.totalHours;

      final topTracks = tracks.take(5).map(_TrackSummary.fromTrack).toList();

      if (!mounted) return;
      setState(() {
        _topTracks = topTracks;
        _topAlbums = computedTopAlbums;
        _topArtists = computedTopArtists;
        _totalPlays = statsResult.totalPlays;
        _totalHours = actualHours;
        _genrePlayCounts = statsResult.genrePlayCounts;
        _codecBreakdown = statsResult.codecCounts;
        _highestQualityTrack = summaryAt(statsResult.highestQualityTrackIndex);
        _mostCommonFormat = statsResult.mostCommonFormat;
        _libraryTracks = statsResult.uniqueTracksCount;
        _libraryAlbums = statsResult.uniqueAlbumsCount;
        _libraryArtists = statsResult.uniqueArtistsCount;
        _avgTrackLength = statsResult.avgTrackLength;
        _longestTrack = summaryAt(statsResult.longestTrackIndex);
        _shortestTrack = summaryAt(statsResult.shortestTrackIndex);
        _uniqueArtistsPlayed = statsResult.uniqueArtistsCount;
        _uniqueAlbumsPlayed = statsResult.uniqueAlbumsCount;
        _uniqueTracksPlayed = statsResult.uniqueTracksCount;
        _diversityScore = statsResult.diversityScore;
        _statsLoading = false;
      });

      // Extract colours from the top track (bounded by a timeout, never
      // throws), then cache whatever we have.
      if (topTracks.isNotEmpty) {
        await _extractColors(topTracks.first);
      }
      await _saveStatsToCache(cacheScope);
    } catch (e) {
      debugPrint('Error loading stats: $e');
      if (mounted) {
        setState(() {
          _statsLoading = false;
        });
      }
    }
  }

  Future<void> _saveStatsToCache(String scope) async {
    final cacheData = <String, dynamic>{
      'totalPlays': _totalPlays,
      'totalHours': _totalHours,
      'uniqueArtists': _uniqueArtistsPlayed,
      'uniqueAlbums': _uniqueAlbumsPlayed,
      'uniqueTracks': _uniqueTracksPlayed,
      'diversityScore': _diversityScore,
      'genrePlayCounts': _genrePlayCounts,
      'topArtists': _topArtists?.map((a) => {
        'name': a.name,
        'playCount': a.playCount,
        'id': a.id,
        'imageTag': a.imageTag,
      }).toList(),
      'topAlbums': _topAlbums?.map((a) => {
        'albumId': a.albumId,
        'name': a.name,
        'artistName': a.artistName,
        'playCount': a.playCount,
        'imageTag': a.imageTag,
      }).toList(),
      'topTracks': _topTracks?.map((t) => t.toJson()).toList(),
      'avgTrackLengthMs': _avgTrackLength?.inMilliseconds,
      'longestTrack': _longestTrack?.toJson(),
      'shortestTrack': _shortestTrack?.toJson(),
      'highestQualityTrack': _highestQualityTrack?.toJson(),
      'codecBreakdown': _codecBreakdown,
      'mostCommonFormat': _mostCommonFormat,
      'paletteColors': _paletteColors?.map((c) => c.toARGB32()).toList(),
    };
    try {
      await ProfileStatsCache.save(scope, cacheData);
      debugPrint('ProfileScreen: Stats cached');
    } catch (e) {
      debugPrint('ProfileScreen: Failed to cache stats: $e');
    }
  }

  /// Tints the header from the top track's artwork. Completes (without
  /// throwing) even when the image fails to load or never arrives.
  Future<void> _extractColors(_TrackSummary track) async {
    final itemId = track.imageItemId;
    final imageTag = track.imageTag;
    if (itemId == null || imageTag == null) return;

    final appState = Provider.of<NautuneAppState>(context, listen: false);
    ImageStream? imageStream;
    ImageStreamListener? listener;

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

      final completer = Completer<ui.Image>();
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info.image);
        },
        onError: (error, stackTrace) {
          if (!completer.isCompleted) completer.completeError(error, stackTrace);
        },
      );
      imageStream = imageProvider.resolve(const ImageConfiguration());
      imageStream.addListener(listener);

      final image = await completer.future.timeout(const Duration(seconds: 10));
      final byteData = await image.toByteData();
      if (byteData == null) return;

      // Quantize in an isolate; the helper converts the raw RGBA bytes to
      // the ARGB order the quantizer expects.
      final colorInts = await compute(
        extractArtworkColorsInIsolate,
        byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
      );
      final selectedColors = colorInts
          .where((c) => Hct.fromInt(c).chroma > 5)
          .take(3)
          .map((c) => Color(c | 0xFF000000))
          .toList();

      if (mounted && selectedColors.isNotEmpty) {
        setState(() {
          _paletteColors = selectedColors;
        });
      }
    } catch (e) {
      debugPrint('Failed to extract colors for profile: $e');
    } finally {
      if (listener != null) imageStream?.removeListener(listener);
    }
  }

  String? _getProfileImageUrl() {
    final sessionProvider = Provider.of<SessionProvider>(context, listen: false);
    final session = sessionProvider.session;
    if (session == null) return null;
    // Spec-documented `GET /UserImage?userId=…` (the legacy
    // `/Users/{id}/Images/Primary` alias is absent from the 10.11/12.1 specs).
    // The image tag (once the profile has loaded) makes a changed picture a
    // new URL; without it the cached one would be shown forever.
    final tag = _user?.primaryImageTag;
    return buildServerUrl(session.serverUrl, '/UserImage', {
      'userId': session.credentials.userId,
      'tag': ?tag,
    });
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
              actions: [
                IconButton(
                  tooltip: _bentoMode ? 'Show detailed stats' : 'Show bento overview',
                  icon: Icon(_bentoMode ? Icons.view_list : Icons.dashboard_rounded),
                  onPressed: () => setState(() => _bentoMode = !_bentoMode),
                ),
              ],
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
                                                style: theme.textTheme.headlineSmall?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                  color: theme.colorScheme.onSurface,
                                                  shadows: [
                                                    Shadow(
                                                      offset: const Offset(0, 2),
                                                      blurRadius: 4,
                                                      color: theme.colorScheme.surface.withValues(alpha: 0.6),
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
                                                      color: NautuneFeatureColors.listenBrainzOrange.withValues(alpha: 0.9),
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

          // Stats content - Split into multiple slivers for better performance
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _bentoMode
                  ? _buildBentoOverview(theme)
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Hero Ring - Total hours with animated progress
                  _buildHeroRing(theme),

                  // Quick Stats Badges (inline below hero)
                  _buildQuickStatsBadges(theme),
                  const SizedBox(height: 16),

                  // 2. Key Metrics - Plays, Artists, Albums (3 cards)
                  _buildKeyMetricsRow(theme),
                  const SizedBox(height: 16),

                  // 3. Library Overview Card - "Your Musical Ocean"
                  _buildLibraryOverviewCard(theme),
                  const SizedBox(height: 12),

                  // Sync Status Banner (only if unsynced plays exist)
                  if (_unsyncedPlays > 0) ...[
                    _buildSyncStatusBanner(theme),
                    const SizedBox(height: 12),
                  ],

                  // ListenBrainz Stats (if connected)
                  if (ListenBrainzService().isConfigured) ...[
                    _buildListenBrainzStatsRow(theme),
                    const SizedBox(height: 12),
                  ],

                  _buildWaveDivider(theme),

                  // 4. Listening Patterns - Enhanced with Peak Day and Marathons
                  _buildNauticalSectionHeader(theme, 'Listening Patterns', Icons.auto_graph),
                  const SizedBox(height: 12),
                  _buildEnhancedListeningPatterns(theme),
                  const SizedBox(height: 16),

                  // 5. Audiophile Stats Card
                  _buildAudiophileStatsCard(theme),

                  _buildWaveDivider(theme),

                  // 6. Top Content Tabs - Tracks | Artists | Albums
                  _buildNauticalSectionHeader(theme, 'Top Content', Icons.star),
                  const SizedBox(height: 12),
                  _buildTopContentTabs(theme),
                  const SizedBox(height: 16),

                  // 7. On This Day Section (collapsible)
                  _buildOnThisDaySection(theme),
                ],
              ),
            ),
          ),

          // Listening Activity Section (lazy loaded)
          if (!_bentoMode && (_heatmap != null || _streak != null))
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildWaveDivider(theme),
                    _buildNauticalSectionHeader(theme, 'Listening Activity', Icons.insights),
                    const SizedBox(height: 12),
                    _buildListeningActivitySection(theme),
                  ],
                ),
              ),
            ),

          // Deep Dive Section
          if (!_bentoMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildWaveDivider(theme),
                    _buildNauticalSectionHeader(theme, 'Deep Dive', Icons.explore),
                    const SizedBox(height: 12),
                    _buildListeningInsights(theme),
                    const SizedBox(height: 16),
                    _buildSoundDNA(theme),
                    const SizedBox(height: 16),
                    _buildGenreBreakdown(theme),
                    const SizedBox(height: 16),
                    _buildMonthlyComparison(theme),
                    const SizedBox(height: 16),
                    _buildYearlyComparison(theme),
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
                memCacheWidth: 240,
                memCacheHeight: 240,
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

  /// Bento-style overview. Compact, landing-style layout that replaces the
  /// long-scroll stats when `_bentoMode` is true. Tap any card to expand
  /// the full detail view via the AppBar toggle (switches to legacy mode
  /// so every section is visible at once, no sheet required).
  ///
  /// Layout (portrait):
  ///  ┌─────────────────────────────────────┐
  ///  │   ◯ Hero ring  │  Plays            │
  ///  │   (XL)         │  Artists          │
  ///  │                │  Albums           │
  ///  ├────────────────┴──────────────────-┤
  ///  │  badges: streak, faves, discovery   │
  ///  ├─────────────────────────────────────┤
  ///  │  Library Ocean card (full width)    │
  ///  └─────────────────────────────────────┘
  Widget _buildBentoOverview(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hero row: ring on the left, key metrics stacked on the right.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: _buildHeroRing(theme, compact: true)),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    Expanded(child: _bentoMini(theme, Icons.play_arrow, '$_totalPlays', 'Plays')),
                    const SizedBox(height: 8),
                    Expanded(child: _bentoMini(theme, Icons.person, '$_uniqueArtistsPlayed', 'Artists')),
                    const SizedBox(height: 8),
                    Expanded(child: _bentoMini(theme, Icons.album, '$_uniqueAlbumsPlayed', 'Albums')),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildQuickStatsBadges(theme),
        const SizedBox(height: 8),
        _buildLibraryOverviewCard(theme),
        const SizedBox(height: 12),
        // Footer hint — how to see everything.
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Tap the list icon above to see every stat',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Compact stat tile used in the bento overview's top row.
  Widget _bentoMini(ThemeData theme, IconData icon, String value, String label) {
    final primary = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.18),
            primary.withValues(alpha: 0.05),
          ],
        ),
        border: Border.all(color: primary.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroRing(ThemeData theme, {bool compact = false}) {
    final oceanBlue = theme.colorScheme.tertiary;
    final deepPurple = theme.colorScheme.secondary;

    // Progress toward goal (e.g., 100 hours)
    const goalHours = 100.0;
    final progress = (_totalHours / goalHours).clamp(0.0, 1.0);

    return Container(
      padding: EdgeInsets.all(compact ? 16 : 24),
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
            color: oceanBlue.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          _HeroRingBox(
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

  Widget _buildKeyMetricsRow(ThemeData theme) {
    final oceanBlue = theme.colorScheme.tertiary;
    const emeraldSea = NautuneFeatureColors.verdantGreen;
    const goldTreasure = NautuneFeatureColors.treasureGold;

    final weekChange = _weekComparison;

    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            theme,
            icon: Icons.play_circle_filled,
            label: 'Total Plays',
            value: _totalPlays > 0 ? _formatNumber(_totalPlays) : '-',
            color: oceanBlue,
            numericValue: _totalPlays > 0 ? _totalPlays : null,
            trendPercent: weekChange?.playsChangePercent,
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
            numericValue: _uniqueArtistsPlayed > 0 ? _uniqueArtistsPlayed : null,
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
            numericValue: _uniqueAlbumsPlayed > 0 ? _uniqueAlbumsPlayed : null,
          ),
        ),
      ],
    );
  }

  Widget _buildListenBrainzStatsRow(ThemeData theme) {
    final listenBrainz = ListenBrainzService();
    final config = listenBrainz.config;
    const listenBrainzOrange = NautuneFeatureColors.listenBrainzOrange;

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
            ? NautuneFeatureColors.verdantGreen.withValues(alpha: 0.1)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOnline
              ? NautuneFeatureColors.verdantGreen.withValues(alpha: 0.3)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isOnline ? Icons.cloud_upload : Icons.cloud_off,
            size: 18,
            color: isOnline
                ? NautuneFeatureColors.verdantGreen
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
                    ? NautuneFeatureColors.verdantGreen
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
    int? numericValue,
    double? trendPercent,
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
          numericValue != null
              ? TweenAnimationBuilder<int>(
                  tween: IntTween(begin: 0, end: numericValue),
                  duration: const Duration(milliseconds: 1200),
                  curve: Curves.easeOutCubic,
                  builder: (context, animatedValue, child) {
                    return Text(
                      _formatNumber(animatedValue),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    );
                  },
                )
              : Text(
                  value,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
          if (trendPercent != null && trendPercent != 0) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  trendPercent > 0 ? Icons.trending_up : Icons.trending_down,
                  size: 12,
                  color: trendPercent > 0
                      ? NautuneFeatureColors.verdantGreen
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 2),
                Text(
                  '${trendPercent > 0 ? '+' : ''}${trendPercent.toStringAsFixed(0)}%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: trendPercent > 0
                        ? NautuneFeatureColors.verdantGreen
                        : theme.colorScheme.error,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
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
          final hasImage = artist.imageTag != null && artist.id != null;

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
                    // Sized to the 80pt circle, with auth headers (not the
                    // full-size original).
                    child: hasImage
                        ? JellyfinImage(
                            itemId: artist.id!,
                            imageTag: artist.imageTag,
                            artistId: artist.id,
                            maxWidth: 80,
                            boxFit: BoxFit.cover,
                            placeholderBuilder: (context, url) => _buildArtistPlaceholder(theme, artist.name),
                            errorBuilder: (context, url, error) => _buildArtistPlaceholder(theme, artist.name),
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
          final hasImage = album.imageTag != null && album.albumId != null;

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
                    // Sized to the 100pt tile, with auth headers.
                    child: hasImage
                        ? JellyfinImage(
                            itemId: album.albumId!,
                            imageTag: album.imageTag,
                            albumId: album.albumId,
                            maxWidth: 100,
                            boxFit: BoxFit.cover,
                            placeholderBuilder: (context, url) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.album,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            errorBuilder: (context, url, error) => Container(
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

    final comparison = _monthComparison;
    if (comparison == null) return const SizedBox.shrink();

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

    final comparison = _yearComparison;
    if (comparison == null) return const SizedBox.shrink();

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
        : (isPositive ? NautuneFeatureColors.verdantGreen : theme.colorScheme.error);

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
      final hours = d.inHours;
      final mins = d.inMinutes.remainder(60);
      final secs = d.inSeconds % 60;
      if (hours > 0) {
        return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
      }
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
                  color: NautuneFeatureColors.treasureGold,
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
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(height: 12),
          ],
          if (_shortestTrack != null)
            _buildTrackInsightRow(
              theme,
              icon: Icons.trending_down,
              label: 'Shortest Track',
              track: _shortestTrack!,
              color: theme.colorScheme.tertiary,
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
    required _TrackSummary track,
    required Color color,
  }) {
    final duration = track.duration;
    String durationStr = '';
    if (duration != null) {
      final hours = duration.inHours;
      final mins = duration.inMinutes.remainder(60);
      final secs = duration.inSeconds % 60;
      durationStr = hours > 0
          ? '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}'
          : '$mins:${secs.toString().padLeft(2, '0')}';
    }

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

  Widget _buildSoundDNA(ThemeData theme) {
    if (_genrePlayCounts == null || _genrePlayCounts!.isEmpty) {
      return const SizedBox.shrink();
    }

    final total = _genrePlayCounts!.values.fold(0, (a, b) => a + b);
    if (total <= 0) return const SizedBox.shrink();
    final entries = _genrePlayCounts!.entries.take(5).toList();
    final colors = [
      theme.colorScheme.primary,
      theme.colorScheme.secondary,
      theme.colorScheme.tertiary,
      Colors.orange,
      Colors.purple,
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.08),
            theme.colorScheme.tertiary.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Text(
            'Your Sound DNA',
            style: _sectionTitleStyle(
              fontSize: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 140,
            width: 140,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1500),
              curve: Curves.easeOutCubic,
              builder: (context, animValue, child) {
                return CustomPaint(
                  size: const Size(140, 140),
                  painter: _SoundDNAPainter(
                    entries:
                        entries.map((e) => e.value / total).toList(),
                    colors: colors.take(entries.length).toList(),
                    animationProgress: animValue,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: entries.asMap().entries.map((e) {
              final color = colors[e.key];
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    e.value.key,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
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
    if (total <= 0) {
      return _buildEmptyCard(theme, 'No genre data available');
    }
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

    final entries = _genrePlayCounts!.entries.toList();

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stacked horizontal bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 24,
              child: Row(
                children: entries.asMap().entries.map((entry) {
                  final index = entry.key;
                  final percentage = entry.value.value / total;
                  return Expanded(
                    flex: (percentage * 1000).round().clamp(1, 1000),
                    child: Container(
                        color: colors[index % colors.length]),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Genre chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entries.asMap().entries.map((entry) {
              final index = entry.key;
              final genre = entry.value.key;
              final count = entry.value.value;
              final percentage = count / total;
              final color = colors[index % colors.length];
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      genre,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${(percentage * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
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

        // Activity Sparkline (last 28 days)
        if (_analyticsService != null) ...[
          const SizedBox(height: 16),
          _buildActivitySparkline(theme),
        ],

        if (_heatmap != null)
          const SizedBox(height: 16),

        // Listening Heatmap
        if (_heatmap != null)
          _buildListeningHeatmap(theme),

      ],
    );
  }

  Widget _buildActivitySparkline(ThemeData theme) {
    final dailyCounts = _dailyPlayCounts;
    if (dailyCounts == null || dailyCounts.length < 2 || dailyCounts.every((c) => c == 0)) {
      return const SizedBox.shrink();
    }

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
              Icon(Icons.show_chart,
                  color: theme.colorScheme.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Last 4 Weeks',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              Text(
                '${dailyCounts.last} today',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(
                data: dailyCounts,
                lineColor: theme.colorScheme.primary,
                fillColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              ),
            ),
          ),
        ],
      ),
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
                color: NautuneFeatureColors.verdantGreen.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle, color: NautuneFeatureColors.verdantGreen, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    'Today',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: NautuneFeatureColors.verdantGreen,
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
                color: isUp ? NautuneFeatureColors.verdantGreen : (isDown ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant),
                size: 16,
              ),
              const SizedBox(width: 4),
              Text(
                isUp
                    ? '+${playsChange.toStringAsFixed(0)}%'
                    : '${playsChange.toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isUp ? NautuneFeatureColors.verdantGreen : (isDown ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant),
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

  /// Build Quick Stats Badges below Hero Ring
  Widget _buildQuickStatsBadges(ThemeData theme) {
    final streak = _streak;
    final analytics = ListeningAnalyticsService();
    final discoveryLabel = analytics.getDiscoveryLabel(_discoveryRate);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          // Streak badge
          if (streak != null && streak.currentStreak > 0)
            _buildQuickBadge(
              theme,
              icon: Icons.local_fire_department,
              text: '${streak.currentStreak} day streak',
              color: Colors.orange,
            ),
          // Favorites badge
          if (_favoritesCount > 0)
            _buildQuickBadge(
              theme,
              icon: Icons.favorite,
              text: '$_favoritesCount faves',
              color: theme.colorScheme.secondary,
            ),
          // Discovery badge
          _buildQuickBadge(
            theme,
            icon: Icons.explore,
            text: discoveryLabel,
            color: NautuneFeatureColors.verdantGreen,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickBadge(
    ThemeData theme, {
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// Build Library Overview Card
  Widget _buildLibraryOverviewCard(ThemeData theme) {
    final oceanBlue = theme.colorScheme.tertiary;
    const emeraldSea = NautuneFeatureColors.verdantGreen;
    const goldTreasure = NautuneFeatureColors.treasureGold;
    final pinkCoral = theme.colorScheme.secondary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            oceanBlue.withValues(alpha: 0.1),
            emeraldSea.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: oceanBlue.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.waves, color: oceanBlue, size: 20),
              const SizedBox(width: 8),
              Text(
                'Your Musical Ocean',
                style: _sectionTitleStyle(fontSize: 16, color: oceanBlue),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'What you\'ve played in this library',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildLibraryBadge(
                  theme,
                  icon: Icons.music_note,
                  value: _formatNumber(_libraryTracks),
                  label: 'Tracks',
                  color: oceanBlue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildLibraryBadge(
                  theme,
                  icon: Icons.album,
                  value: _formatNumber(_libraryAlbums),
                  label: 'Albums',
                  color: emeraldSea,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildLibraryBadge(
                  theme,
                  icon: Icons.person,
                  value: _formatNumber(_libraryArtists),
                  label: 'Artists',
                  color: goldTreasure,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildLibraryBadge(
                  theme,
                  icon: Icons.favorite,
                  value: _formatNumber(_favoritesCount),
                  label: 'Faves',
                  color: pinkCoral,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryBadge(
    ThemeData theme, {
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Build Audiophile Stats Card
  Widget _buildAudiophileStatsCard(ThemeData theme) {
    if (_codecBreakdown == null || _codecBreakdown!.isEmpty) {
      return const SizedBox.shrink();
    }

    final deepPurple = theme.colorScheme.secondary;
    final totalTracks = _codecBreakdown!.values.fold<int>(0, (a, b) => a + b);

    // Sort codecs by count
    final sortedCodecs = _codecBreakdown!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            deepPurple.withValues(alpha: 0.15),
            deepPurple.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: deepPurple.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.headphones, color: deepPurple, size: 20),
              const SizedBox(width: 8),
              Text(
                'Audiophile Stats',
                style: _sectionTitleStyle(fontSize: 16, color: deepPurple),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Most common format
          if (_mostCommonFormat != null) ...[
            Row(
              children: [
                Icon(Icons.audio_file, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Most common: ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: deepPurple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _mostCommonFormat!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: deepPurple,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Highest quality track
          if (_highestQualityTrack != null) ...[
            Row(
              children: [
                const Icon(Icons.star, size: 16, color: NautuneFeatureColors.treasureGold),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Best quality:',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        _highestQualityTrack!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_highestQualityTrack!.qualityInfo != null && _highestQualityTrack!.qualityInfo!.isNotEmpty)
                        Text(
                          _highestQualityTrack!.qualityInfo!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: deepPurple,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Format breakdown bars
          Text(
            'Format Breakdown',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ...sortedCodecs.take(5).map((entry) {
            final percentage = entry.value / totalTracks;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 50,
                    child: Text(
                      entry.key,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: percentage,
                        backgroundColor: deepPurple.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(deepPurple),
                        minHeight: 8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${(percentage * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: deepPurple,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  /// Build Enhanced Listening Patterns as a compact 3x2 grid
  Widget _buildEnhancedListeningPatterns(ThemeData theme) {
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.0,
        children: [
          _buildCompactPatternTile(theme,
            icon: Icons.schedule,
            label: 'Peak Hour',
            value: _peakHour != null ? _formatHour(_peakHour!) : '-',
            color: theme.colorScheme.tertiary,
          ),
          _buildCompactPatternTile(theme,
            icon: Icons.today,
            label: 'Peak Day',
            value: _peakDay != null
                ? ListeningAnalyticsService.getShortDayName(_peakDay!)
                : '-',
            color: NautuneFeatureColors.treasureGold,
          ),
          _buildCompactPatternTile(theme,
            icon: Icons.timelapse,
            label: 'Avg Session',
            value: formatSessionLength(_avgSessionLength),
            color: theme.colorScheme.secondary,
          ),
          _buildCompactPatternTile(theme,
            icon: Icons.explore,
            label: 'Discovery',
            value: '${_discoveryRate.toStringAsFixed(0)}%',
            color: NautuneFeatureColors.verdantGreen,
            progress: _discoveryRate / 100,
          ),
          _buildCompactPatternTile(theme,
            icon: Icons.timer,
            label: 'Marathons',
            value: '$_marathonSessions',
            color: Colors.orange,
          ),
          _buildCompactPatternTile(theme,
            icon: Icons.diversity_3,
            label: 'Diversity',
            value: _diversityScore > 0
                ? '${_diversityScore.toStringAsFixed(0)}%'
                : '-',
            color: theme.colorScheme.secondary,
            progress: _diversityScore > 0 ? _diversityScore / 100 : null,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactPatternTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    double? progress,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (progress != null)
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 3,
                backgroundColor: color.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            )
          else
            Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 10,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Build On This Day Section
  Widget _buildOnThisDaySection(ThemeData theme) {
    if (_onThisDayEvents == null || _onThisDayEvents!.isEmpty) {
      return const SizedBox.shrink();
    }

    final now = DateTime.now();
    final monthDay = '${_getMonthName(now.month)} ${now.day}';

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // Header (always visible)
          InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => _onThisDayExpanded = !_onThisDayExpanded);
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.history, color: theme.colorScheme.tertiary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'On This Day ($monthDay)',
                      style: _sectionTitleStyle(
                        fontSize: 16,
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_onThisDayEvents!.length} memories',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _onThisDayExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expanded content
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: _onThisDayEvents!.take(5).map((event) {
                  final monthsAgo = (now.year - event.timestamp.year) * 12 +
                      now.month - event.timestamp.month;
                  final yearsAgo = monthsAgo ~/ 12;
                  String timeAgo;
                  if (yearsAgo >= 1) {
                    timeAgo = yearsAgo == 1 ? '1 year ago' : '$yearsAgo years ago';
                  } else if (monthsAgo >= 1) {
                    timeAgo = monthsAgo == 1 ? '1 month ago' : '$monthsAgo months ago';
                  } else {
                    timeAgo = 'Recently';
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 60,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            timeAgo,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.tertiary,
                              fontSize: 9,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                event.trackName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                event.artists.join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            crossFadeState: _onThisDayExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  /// Build nautical-themed section header
  Widget _buildNauticalSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary, size: 22),
        const SizedBox(width: 10),
        Text(
          title,
          style: _sectionTitleStyle(fontSize: 18, color: theme.colorScheme.primary),
        ),
      ],
    );
  }

  /// Shared section-header text style, derived from the app text theme.
  TextStyle _sectionTitleStyle({required double fontSize, required Color color}) {
    return Theme.of(context).textTheme.titleMedium!.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: color,
        );
  }

  /// Build wave divider between sections
  Widget _buildWaveDivider(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: CustomPaint(
        size: const Size(double.infinity, 12),
        painter: _WavePainter(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}

/// A 180pt square for the hero ring that scales down uniformly when its
/// column is narrower (the bento layout on phones), so the ring stays a
/// circle instead of being squeezed into an oval.
class _HeroRingBox extends StatelessWidget {
  const _HeroRingBox({required this.child});

  static const double _size = 180;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _size),
      child: AspectRatio(
        aspectRatio: 1,
        child: FittedBox(
          child: SizedBox(width: _size, height: _size, child: child),
        ),
      ),
    );
  }
}

/// Sparkline of daily play counts
class _SparklinePainter extends CustomPainter {
  final List<int> data;
  final Color lineColor;
  final Color fillColor;

  _SparklinePainter({
    required this.data,
    required this.lineColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final maxVal = data.reduce(math.max).toDouble();
    if (maxVal == 0) return;

    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - (data[i] / maxVal) * (size.height - 4);
      points.add(Offset(x, y));
    }

    // Draw filled area
    final fillPath = Path()..moveTo(0, size.height);
    for (final p in points) {
      fillPath.lineTo(p.dx, p.dy);
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()..color = fillColor);

    // Draw line
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      linePath.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // Dot on last point (today)
    canvas.drawCircle(points.last, 3, Paint()..color = lineColor);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      !listEquals(old.data, data) || old.lineColor != lineColor;
}

class _SoundDNAPainter extends CustomPainter {
  final List<double> entries;
  final List<Color> colors;
  final double animationProgress;

  _SoundDNAPainter({
    required this.entries,
    required this.colors,
    required this.animationProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    const startAngle = -math.pi / 2;

    for (int i = 0; i < entries.length; i++) {
      final sweepAngle = entries[i] * 2 * math.pi * animationProgress;
      final ringWidth = maxRadius / (entries.length + 1);
      final radius = maxRadius - (i * ringWidth);

      final paint = Paint()
        ..color = colors[i].withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth * 0.8
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(
            center: center, radius: radius - ringWidth / 2),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SoundDNAPainter old) =>
      old.animationProgress != animationProgress ||
      !listEquals(old.entries, entries) ||
      !listEquals(old.colors, colors);
}

class _WavePainter extends CustomPainter {
  final Color color;

  _WavePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height / 2);

    for (double i = 0; i < size.width; i++) {
      path.lineTo(i, size.height / 2 + math.sin(i * 0.05) * 4);
    }

    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
