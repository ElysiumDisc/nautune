import '../jellyfin/jellyfin_service.dart';
import '../models/rewind_data.dart';
import 'listening_analytics_service.dart';

/// Service for computing Rewind (year-in-review) statistics
class RewindService {
  final ListeningAnalyticsService _analytics;

  RewindService({ListeningAnalyticsService? analytics})
      : _analytics = analytics ?? ListeningAnalyticsService();

  /// Get available years for Rewind
  List<int> getAvailableYears() {
    return _analytics.getAvailableYears();
  }

  /// Check if there's enough data for a meaningful Rewind
  /// For previous years, checks local analytics
  /// For null (all time), also checks if server has play data
  bool hasEnoughData(int? year) {
    return _analytics.getTotalPlaysForYear(year) >= 10;
  }

  /// Compute Rewind using server-side data (most accurate for all-time stats)
  /// NOTE: Jellyfin only tracks total play count (all-time), not per-year
  /// - For All Time (year == null): Uses server data for accurate top items
  /// - For specific year: Uses local analytics (server doesn't track per-year)
  Future<RewindData> computeRewindFromServer({
    required JellyfinService jellyfinService,
    required String libraryId,
    int? year,
  }) async {
    // For specific years, use local analytics (server doesn't track per-year stats)
    if (year != null) {
      return computeRewind(year);
    }

    final client = jellyfinService.jellyfinClient;
    final credentials = jellyfinService.session?.credentials;

    if (client == null || credentials == null) {
      // No server connection, use local analytics
      return computeRewind(year);
    }

    try {
      // Fetch ALL tracks to aggregate stats accurately for all-time
      // Jellyfin doesn't return accurate PlayCount for artists/albums directly
      final serverTracks = await client.fetchMostPlayed(
        credentials,
        libraryId: libraryId,
        itemType: 'Audio',
        limit: 10000, // Fetch all tracks for accurate all-time stats
      );

      // Parse track data with album image tags and runtime
      final trackDataList = serverTracks.map((t) {
        final userData = t['UserData'] as Map<String, dynamic>?;
        return _TrackData(
          trackId: t['Id'] as String,
          name: t['Name'] as String? ?? 'Unknown',
          artistName: (t['Artists'] as List?)?.firstOrNull?.toString() ??
                      t['AlbumArtist'] as String? ?? 'Unknown',
          albumName: t['Album'] as String?,
          albumId: t['AlbumId'] as String?,
          albumImageTag: t['AlbumPrimaryImageTag'] as String?,
          playCount: userData?['PlayCount'] as int? ?? 0,
          runTimeTicks: t['RunTimeTicks'] as int?,
        );
      }).toList();

      // Convert to RewindTrack for top tracks
      final allTracks = trackDataList.map((t) => RewindTrack(
        trackId: t.trackId,
        name: t.name,
        artistName: t.artistName,
        albumName: t.albumName,
        albumId: t.albumId,
        playCount: t.playCount,
      )).toList();

      // Get top 10 tracks by play count
      final topTracks = (allTracks.toList()
        ..sort((a, b) => b.playCount.compareTo(a.playCount)))
        .take(10).toList();

      // Aggregate play counts by artist from track data
      final artistPlayCounts = <String, int>{};
      for (final track in trackDataList) {
        final artist = track.artistName;
        artistPlayCounts[artist] = (artistPlayCounts[artist] ?? 0) + track.playCount;
      }

      // Sort by play count and take top 10 artist names
      final sortedArtists = artistPlayCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topArtistNames = sortedArtists.take(10).toList();

      // Look up artist IDs and images from Jellyfin
      final topArtists = <RewindArtist>[];
      for (final entry in topArtistNames) {
        String? artistId;
        String? imageTag;
        try {
          final results = await jellyfinService.searchArtists(
            libraryId: libraryId,
            query: entry.key,
          );
          final match = results.where((a) =>
            a.name.toLowerCase() == entry.key.toLowerCase()
          ).firstOrNull;
          if (match != null) {
            artistId = match.id;
            imageTag = match.primaryImageTag;
          }
        } catch (_) {}
        topArtists.add(RewindArtist(
          name: entry.key,
          playCount: entry.value,
          id: artistId,
          imageTag: imageTag,
        ));
      }

      // Aggregate play counts by album from track data (with image tags)
      final albumPlayCounts = <String, _AlbumData>{};
      for (final track in trackDataList) {
        if (track.albumId != null) {
          final key = track.albumId!;
          if (albumPlayCounts.containsKey(key)) {
            albumPlayCounts[key]!.playCount += track.playCount;
          } else {
            albumPlayCounts[key] = _AlbumData(
              albumId: track.albumId,
              name: track.albumName ?? 'Unknown Album',
              artistName: track.artistName,
              playCount: track.playCount,
              imageTag: track.albumImageTag,
            );
          }
        }
      }

      // Sort by play count and take top 10
      final sortedAlbums = albumPlayCounts.values.toList()
        ..sort((a, b) => b.playCount.compareTo(a.playCount));
      final topAlbums = sortedAlbums.take(10).map((a) => RewindAlbum(
        albumId: a.albumId,
        name: a.name,
        artistName: a.artistName,
        playCount: a.playCount,
        imageTag: a.imageTag,
      )).toList();

      // Calculate total plays from all track data
      final totalPlays = allTracks.fold<int>(0, (sum, t) => sum + t.playCount);

      // Calculate total listening time from server data (playCount * runTimeTicks)
      // RunTimeTicks are in 100-nanosecond intervals (10,000,000 ticks = 1 second)
      int totalTicks = 0;
      for (final track in trackDataList) {
        if (track.runTimeTicks != null) {
          totalTicks += track.runTimeTicks! * track.playCount;
        }
      }
      final totalTime = Duration(microseconds: totalTicks ~/ 10); // Convert ticks to microseconds

      // Get local analytics for patterns (server doesn't track these)
      final genres = _analytics.getGenresForYear(year);
      final topGenre = _analytics.getTopGenreForYear(year);
      final playsByHour = _analytics.getPlaysByHourForYear(year);
      final playsByDayOfWeek = _analytics.getPlaysByDayOfWeekForYear(year);
      final peakMonth = year != null ? _analytics.getPeakMonthForYear(year) : null;
      final longestStreak = year != null ? _analytics.getLongestStreakForYear(year) : 0;
      final discoveryRate = _analytics.getDiscoveryRateForYear(year);

      final personality = _computePersonality(
        discoveryRate: discoveryRate,
        playsByHour: playsByHour,
        playsByDayOfWeek: playsByDayOfWeek,
        genres: genres,
        totalPlays: totalPlays,
      );

      return RewindData(
        year: year,
        totalPlays: totalPlays > 0 ? totalPlays : _analytics.getTotalPlaysForYear(year),
        totalTime: totalTime,
        topArtists: topArtists.isNotEmpty ? topArtists : _getLocalTopArtists(year),
        topAlbums: topAlbums.isNotEmpty ? topAlbums : _getLocalTopAlbums(year),
        topTracks: topTracks.isNotEmpty ? topTracks : _getLocalTopTracks(year),
        topGenre: topGenre,
        genres: genres,
        peakMonth: peakMonth,
        longestStreak: longestStreak,
        uniqueArtists: _analytics.getUniqueArtistsForYear(year),
        uniqueTracks: _analytics.getUniqueTracksForYear(year),
        uniqueAlbums: _analytics.getUniqueAlbumsForYear(year),
        discoveryRate: discoveryRate,
        personality: personality,
        playsByHour: playsByHour,
        playsByDayOfWeek: playsByDayOfWeek,
      );
    } catch (e) {
      // Server fetch failed, fall back to local analytics
      return computeRewind(year);
    }
  }

  List<RewindArtist> _getLocalTopArtists(int? year) {
    return _analytics.getTopArtistsForYear(year, limit: 10).map((a) => RewindArtist(
      name: a['name'] as String,
      playCount: a['playCount'] as int,
    )).toList();
  }

  List<RewindAlbum> _getLocalTopAlbums(int? year) {
    return _analytics.getTopAlbumsForYear(year, limit: 10).map((a) => RewindAlbum(
      albumId: a['albumId'] as String?,
      name: a['name'] as String,
      artistName: a['artistName'] as String,
      playCount: a['playCount'] as int,
    )).toList();
  }

  List<RewindTrack> _getLocalTopTracks(int? year) {
    return _analytics.getTopTracksForYear(year, limit: 10).map((t) => RewindTrack(
      trackId: t['trackId'] as String,
      name: t['name'] as String,
      artistName: t['artistName'] as String,
      albumName: t['albumName'] as String?,
      albumId: t['albumId'] as String?,
      playCount: t['playCount'] as int,
    )).toList();
  }

  /// Compute full Rewind data for a specific year (null = all time)
  RewindData computeRewind(int? year) {
    final totalPlays = _analytics.getTotalPlaysForYear(year);
    final totalTime = _analytics.getTotalListeningTimeForYear(year);

    // Top content
    final topArtistsRaw = _analytics.getTopArtistsForYear(year, limit: 10);
    final topAlbumsRaw = _analytics.getTopAlbumsForYear(year, limit: 10);
    final topTracksRaw = _analytics.getTopTracksForYear(year, limit: 10);

    final topArtists = topArtistsRaw.map((a) => RewindArtist(
      name: a['name'] as String,
      playCount: a['playCount'] as int,
    )).toList();

    final topAlbums = topAlbumsRaw.map((a) => RewindAlbum(
      albumId: a['albumId'] as String?,
      name: a['name'] as String,
      artistName: a['artistName'] as String,
      playCount: a['playCount'] as int,
    )).toList();

    final topTracks = topTracksRaw.map((t) => RewindTrack(
      trackId: t['trackId'] as String,
      name: t['name'] as String,
      artistName: t['artistName'] as String,
      albumName: t['albumName'] as String?,
      albumId: t['albumId'] as String?,
      playCount: t['playCount'] as int,
    )).toList();

    // Genres
    final topGenre = _analytics.getTopGenreForYear(year);
    final genres = _analytics.getGenresForYear(year);

    // Stats
    final peakMonth = year != null ? _analytics.getPeakMonthForYear(year) : null;
    final longestStreak = year != null ? _analytics.getLongestStreakForYear(year) : 0;
    final uniqueArtists = _analytics.getUniqueArtistsForYear(year);
    final uniqueTracks = _analytics.getUniqueTracksForYear(year);
    final uniqueAlbums = _analytics.getUniqueAlbumsForYear(year);
    final discoveryRate = _analytics.getDiscoveryRateForYear(year);

    // Time patterns
    final playsByHour = _analytics.getPlaysByHourForYear(year);
    final playsByDayOfWeek = _analytics.getPlaysByDayOfWeekForYear(year);

    // Compute personality
    final personality = _computePersonality(
      discoveryRate: discoveryRate,
      playsByHour: playsByHour,
      playsByDayOfWeek: playsByDayOfWeek,
      genres: genres,
      totalPlays: totalPlays,
    );

    return RewindData(
      year: year,
      totalPlays: totalPlays,
      totalTime: totalTime,
      topArtists: topArtists,
      topAlbums: topAlbums,
      topTracks: topTracks,
      topGenre: topGenre,
      genres: genres,
      peakMonth: peakMonth,
      longestStreak: longestStreak,
      uniqueArtists: uniqueArtists,
      uniqueTracks: uniqueTracks,
      uniqueAlbums: uniqueAlbums,
      discoveryRate: discoveryRate,
      personality: personality,
      playsByHour: playsByHour,
      playsByDayOfWeek: playsByDayOfWeek,
    );
  }

  /// Compute the listener's personality archetype based on their patterns
  ListeningPersonality _computePersonality({
    required double discoveryRate,
    required Map<int, int> playsByHour,
    required Map<int, int> playsByDayOfWeek,
    required Map<String, int> genres,
    required int totalPlays,
  }) {
    if (totalPlays < 10) {
      return ListeningPersonality.balanced;
    }

    // Calculate various metrics
    final nightPlays = _countNightPlays(playsByHour);
    final morningPlays = _countMorningPlays(playsByHour);
    final weekendPlays = _countWeekendPlays(playsByDayOfWeek);
    final totalPlaysFromHours = playsByHour.values.fold(0, (a, b) => a + b);
    final totalPlaysFromDays = playsByDayOfWeek.values.fold(0, (a, b) => a + b);

    // Night owl: >40% of plays between 10pm-4am
    if (totalPlaysFromHours > 0 && nightPlays / totalPlaysFromHours > 0.4) {
      return ListeningPersonality.nightOwl;
    }

    // Early bird: >30% of plays between 5am-8am
    if (totalPlaysFromHours > 0 && morningPlays / totalPlaysFromHours > 0.3) {
      return ListeningPersonality.earlyBird;
    }

    // Weekend warrior: >50% of plays on weekends
    if (totalPlaysFromDays > 0 && weekendPlays / totalPlaysFromDays > 0.5) {
      return ListeningPersonality.weekendWarrior;
    }

    // Explorer: high discovery rate (>70%)
    if (discoveryRate > 70) {
      return ListeningPersonality.explorer;
    }

    // Loyalist: low discovery rate (<25%)
    if (discoveryRate < 25) {
      return ListeningPersonality.loyalist;
    }

    // Eclectic: many genres (>8 with significant plays)
    final significantGenres = genres.values.where((c) => c > 5).length;
    if (significantGenres >= 8) {
      return ListeningPersonality.eclectic;
    }

    // Specialist: 1-2 dominant genres (>70% of plays)
    if (genres.isNotEmpty) {
      final topGenreCount = genres.values.reduce((a, b) => a > b ? a : b);
      final totalGenrePlays = genres.values.fold(0, (a, b) => a + b);
      if (totalGenrePlays > 0 && topGenreCount / totalGenrePlays > 0.7) {
        return ListeningPersonality.specialist;
      }
    }

    return ListeningPersonality.balanced;
  }

  int _countNightPlays(Map<int, int> playsByHour) {
    // 10pm (22) to 4am (3)
    int count = 0;
    for (int hour = 22; hour <= 23; hour++) {
      count += playsByHour[hour] ?? 0;
    }
    for (int hour = 0; hour <= 3; hour++) {
      count += playsByHour[hour] ?? 0;
    }
    return count;
  }

  int _countMorningPlays(Map<int, int> playsByHour) {
    // 5am to 8am
    int count = 0;
    for (int hour = 5; hour <= 8; hour++) {
      count += playsByHour[hour] ?? 0;
    }
    return count;
  }

  int _countWeekendPlays(Map<int, int> playsByDayOfWeek) {
    // Saturday (5) and Sunday (6)
    return (playsByDayOfWeek[5] ?? 0) + (playsByDayOfWeek[6] ?? 0);
  }
}

/// Helper class for track data with image tags
class _TrackData {
  final String trackId;
  final String name;
  final String artistName;
  final String? albumName;
  final String? albumId;
  final String? albumImageTag;
  final int playCount;
  final int? runTimeTicks;

  _TrackData({
    required this.trackId,
    required this.name,
    required this.artistName,
    this.albumName,
    this.albumId,
    this.albumImageTag,
    required this.playCount,
    this.runTimeTicks,
  });
}

/// Helper class for aggregating album data
class _AlbumData {
  final String? albumId;
  final String name;
  final String artistName;
  final String? imageTag;
  int playCount;

  _AlbumData({
    this.albumId,
    required this.name,
    required this.artistName,
    this.imageTag,
    required this.playCount,
  });
}
