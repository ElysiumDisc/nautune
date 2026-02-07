import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/listenbrainz_config.dart';

/// Service for ListenBrainz integration (scrobbling + recommendations)
class ListenBrainzService {
  static const _baseUrl = 'https://api.listenbrainz.org/1';
  static const _musicBrainzUrl = 'https://musicbrainz.org/ws/2';
  static const _boxName = 'listenbrainz_config';
  static const _configKey = 'config';
  static const _pendingScrobblesKey = 'pending_scrobbles';

  Box? _box;
  ListenBrainzConfig? _config;
  bool _initialized = false;

  // Pending scrobbles for offline support
  List<Map<String, dynamic>> _pendingScrobbles = [];

  // Cache for MusicBrainz recording metadata (MBID -> {trackName, artistName})
  // Bounded to prevent unbounded memory growth during long sessions.
  static final Map<String, Map<String, String>> _mbMetadataCache = {};
  static const int _mbCacheMaxSize = 200;

  // Cache for popularity data (expires after 7 days)
  static const _popularityCacheBoxName = 'listenbrainz_popularity_cache';
  static const _popularityCacheTtlDays = 7;
  Box? _popularityCacheBox;

  // Singleton
  static final ListenBrainzService _instance = ListenBrainzService._internal();
  factory ListenBrainzService() => _instance;
  ListenBrainzService._internal();

  bool get isInitialized => _initialized;
  bool get isConfigured => _config != null;
  bool get isScrobblingEnabled => _config?.scrobblingEnabled ?? false;
  ListenBrainzConfig? get config => _config;
  String? get username => _config?.username;
  int get pendingScrobblesCount => _pendingScrobbles.length;

  /// Reset the local scrobble count (use when count is out of sync)
  Future<void> resetScrobbleCount(int newCount) async {
    if (_config == null) return;
    _config = _config!.copyWith(totalScrobbles: newCount);
    await _saveConfig();
    debugPrint('ListenBrainzService: Reset scrobble count to $newCount');
  }

  /// Sync local scrobble count with ListenBrainz server
  /// Returns the synced count, or -1 on error
  /// Note: Only updates if server count is higher (server count can be delayed/cached)
  Future<int> syncScrobbleCount() async {
    if (!_initialized || _config == null) return -1;

    const maxRetries = 3;
    const initialDelay = Duration(seconds: 1);

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final response = await http.get(
          Uri.parse('$_baseUrl/user/${_config!.username}/listen-count'),
          headers: {
            'Authorization': 'Token ${_config!.token}',
          },
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final payload = data['payload'] as Map<String, dynamic>?;
          final serverCount = payload?['count'] as int? ?? 0;
          final localCount = _config!.totalScrobbles;

          // Only update if server count is higher or equal
          // (server count API can be cached/delayed, don't lose recent local scrobbles)
          if (serverCount >= localCount) {
            _config = _config!.copyWith(totalScrobbles: serverCount);
            await _saveConfig();
            debugPrint('ListenBrainzService: Synced scrobble count from server: $serverCount');
          } else {
            debugPrint('ListenBrainzService: Server count ($serverCount) is less than local ($localCount) - keeping local (server may be cached)');
          }

          return serverCount;
        } else if (response.statusCode >= 500 || response.statusCode == 429) {
          debugPrint('ListenBrainzService: Sync count failed: ${response.statusCode}, attempt ${attempt + 1}/$maxRetries');
          if (attempt < maxRetries - 1) {
            await Future.delayed(initialDelay * (1 << attempt));
            continue;
          }
        } else {
          debugPrint('ListenBrainzService: Failed to sync count: ${response.statusCode}');
          return -1;
        }
      } on TimeoutException {
        debugPrint('ListenBrainzService: Sync count timeout, attempt ${attempt + 1}/$maxRetries');
        if (attempt < maxRetries - 1) {
          await Future.delayed(initialDelay * (1 << attempt));
          continue;
        }
      } catch (e) {
        debugPrint('ListenBrainzService: Sync count error: $e, attempt ${attempt + 1}/$maxRetries');
        if (attempt < maxRetries - 1) {
          await Future.delayed(initialDelay * (1 << attempt));
          continue;
        }
      }
    }

    return -1;
  }

  /// Force sync count from server, even if lower than local
  /// Use this only when you're sure local count is wrong
  Future<int> forceSyncScrobbleCount() async {
    if (!_initialized || _config == null) return -1;

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/user/${_config!.username}/listen-count'),
        headers: {
          'Authorization': 'Token ${_config!.token}',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final payload = data['payload'] as Map<String, dynamic>?;
        final count = payload?['count'] as int? ?? 0;

        _config = _config!.copyWith(totalScrobbles: count);
        await _saveConfig();

        debugPrint('ListenBrainzService: Force synced scrobble count from server: $count');
        return count;
      }
      debugPrint('ListenBrainzService: Failed to force sync count: ${response.statusCode}');
      return -1;
    } catch (e) {
      debugPrint('ListenBrainzService: Error force syncing count: $e');
      return -1;
    }
  }

  /// Initialize the service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _box = await Hive.openBox(_boxName);
      _popularityCacheBox = await Hive.openBox(_popularityCacheBoxName);
      await _loadConfig();
      await _loadPendingScrobbles();
      _initialized = true;
      debugPrint('ListenBrainzService: Initialized${_config != null ? " (connected as ${_config!.username})" : ""}');
    } catch (e) {
      debugPrint('ListenBrainzService: Failed to initialize: $e');
    }
  }

  Future<void> _loadConfig() async {
    final raw = _box?.get(_configKey);
    if (raw == null) return;

    try {
      if (raw is String) {
        _config = ListenBrainzConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } else if (raw is Map) {
        _config = ListenBrainzConfig.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (e) {
      debugPrint('ListenBrainzService: Error loading config: $e');
    }
  }

  Future<void> _saveConfig() async {
    if (_box == null || _config == null) return;
    await _box!.put(_configKey, jsonEncode(_config!.toJson()));
  }

  Future<void> _loadPendingScrobbles() async {
    final raw = _box?.get(_pendingScrobblesKey);
    if (raw == null) return;

    try {
      if (raw is String) {
        _pendingScrobbles = (jsonDecode(raw) as List)
            .cast<Map<String, dynamic>>();
      } else if (raw is List) {
        _pendingScrobbles = raw.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('ListenBrainzService: Error loading pending scrobbles: $e');
      _pendingScrobbles = [];
    }
  }

  Future<void> _savePendingScrobbles() async {
    if (_box == null) return;
    await _box!.put(_pendingScrobblesKey, jsonEncode(_pendingScrobbles));
  }

  /// Validate a ListenBrainz user token
  Future<bool> validateToken(String token) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/validate-token'),
        headers: {
          'Authorization': 'Token $token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['valid'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('ListenBrainzService: Token validation error: $e');
      return false;
    }
  }

  /// Save credentials and connect account
  Future<bool> saveCredentials(String username, String token) async {
    if (!_initialized) await initialize();

    // Validate token first
    final isValid = await validateToken(token);
    if (!isValid) {
      debugPrint('ListenBrainzService: Invalid token');
      return false;
    }

    _config = ListenBrainzConfig(
      username: username,
      token: token,
      scrobblingEnabled: true,
    );
    await _saveConfig();

    debugPrint('ListenBrainzService: Connected as $username');
    return true;
  }

  /// Disconnect account
  Future<void> disconnect() async {
    _config = null;
    _pendingScrobbles.clear();
    await _box?.delete(_configKey);
    await _box?.delete(_pendingScrobblesKey);
    debugPrint('ListenBrainzService: Disconnected');
  }

  /// Toggle scrobbling on/off
  Future<void> setScrobblingEnabled(bool enabled) async {
    if (_config == null) return;
    _config = _config!.copyWith(scrobblingEnabled: enabled);
    await _saveConfig();
    debugPrint('ListenBrainzService: Scrobbling ${enabled ? "enabled" : "disabled"}');
  }

  /// Submit a listen (scrobble) to ListenBrainz
  Future<bool> submitListen(JellyfinTrack track, DateTime listenedAt) async {
    if (!_initialized || _config == null || !_config!.scrobblingEnabled) {
      debugPrint('ListenBrainzService: Scrobble skipped - not initialized or disabled');
      return false;
    }

    // Validate required fields
    if (track.name.isEmpty || track.displayArtist.isEmpty) {
      debugPrint('ListenBrainzService: Scrobble skipped - missing track name or artist');
      return false;
    }

    final payload = _buildListenPayload(track, listenedAt);
    final requestBody = jsonEncode({
      'listen_type': 'single',
      'payload': [payload],
    });

    debugPrint('ListenBrainzService: Submitting scrobble for "${track.name}" by ${track.displayArtist}');
    debugPrint('ListenBrainzService: Timestamp: ${listenedAt.toIso8601String()} (${listenedAt.millisecondsSinceEpoch ~/ 1000})');

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/submit-listens'),
        headers: {
          'Authorization': 'Token ${_config!.token}',
          'Content-Type': 'application/json',
        },
        body: requestBody,
      ).timeout(const Duration(seconds: 30));

      debugPrint('ListenBrainzService: Response ${response.statusCode}: ${response.body}');

      if (response.statusCode == 200) {
        // Verify response body indicates success
        try {
          final responseData = jsonDecode(response.body);
          final status = responseData['status'] as String?;

          if (status != 'ok') {
            debugPrint('ListenBrainzService: Unexpected response status: $status');
            // Don't increment count if status isn't "ok"
            _queuePendingScrobble(payload);
            return false;
          }
        } catch (e) {
          debugPrint('ListenBrainzService: Could not parse response body: $e');
          // Response might be valid but unparseable, cautiously accept
        }

        // Update stats only after confirmed success
        _config = _config!.copyWith(
          lastScrobbleTime: DateTime.now(),
          totalScrobbles: _config!.totalScrobbles + 1,
        );
        await _saveConfig();

        debugPrint('ListenBrainzService: Scrobbled "${track.name}" successfully');
        return true;
      } else {
        debugPrint('ListenBrainzService: Scrobble failed: ${response.statusCode} - ${response.body}');

        // Queue for retry on server errors or rate limiting
        if (response.statusCode >= 500 || response.statusCode == 429) {
          _queuePendingScrobble(payload);
        }
        // 400/401/403 errors are likely permanent (bad data, auth issues)
        // Don't queue these as they'll keep failing
        return false;
      }
    } on TimeoutException {
      debugPrint('ListenBrainzService: Scrobble timeout - queuing for retry');
      _queuePendingScrobble(payload);
      return false;
    } catch (e) {
      debugPrint('ListenBrainzService: Scrobble error: $e');
      // Queue for offline retry
      _queuePendingScrobble(payload);
      return false;
    }
  }

  /// Submit "now playing" status
  Future<bool> submitNowPlaying(JellyfinTrack track) async {
    if (!_initialized || _config == null || !_config!.scrobblingEnabled) {
      return false;
    }

    // playing_now must NOT include listened_at per ListenBrainz API spec
    final payload = _buildListenPayload(track, null);

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/submit-listens'),
        headers: {
          'Authorization': 'Token ${_config!.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'listen_type': 'playing_now',
          'payload': [payload],
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('ListenBrainzService: Now playing "${track.name}"');
        return true;
      }
      debugPrint('ListenBrainzService: Now playing failed: ${response.statusCode} - ${response.body}');
      return false;
    } catch (e) {
      debugPrint('ListenBrainzService: Now playing error: $e');
      return false;
    }
  }

  /// Build payload for ListenBrainz API
  /// [listenedAt] should be null for playing_now submissions
  Map<String, dynamic> _buildListenPayload(JellyfinTrack track, DateTime? listenedAt) {
    final metadata = <String, dynamic>{
      'artist_name': track.displayArtist,
      'track_name': track.name,
    };

    if (track.album != null) {
      metadata['release_name'] = track.album;
    }

    final additionalInfo = <String, dynamic>{};

    // Add MusicBrainz IDs if available from Jellyfin metadata
    if (track.providerIds != null) {
      if (track.providerIds!['MusicBrainzTrack'] != null) {
        additionalInfo['recording_mbid'] = track.providerIds!['MusicBrainzTrack'];
      }
      if (track.providerIds!['MusicBrainzAlbum'] != null) {
        additionalInfo['release_mbid'] = track.providerIds!['MusicBrainzAlbum'];
      }
      if (track.providerIds!['MusicBrainzArtist'] != null) {
        additionalInfo['artist_mbids'] = [track.providerIds!['MusicBrainzArtist']];
      }
    }

    // Add duration
    if (track.runTimeTicks != null) {
      additionalInfo['duration_ms'] = track.runTimeTicks! ~/ 10000;
    }

    if (additionalInfo.isNotEmpty) {
      metadata['additional_info'] = additionalInfo;
    }

    final payload = <String, dynamic>{
      'track_metadata': metadata,
    };

    // Only include listened_at for actual scrobbles (not playing_now)
    if (listenedAt != null) {
      payload['listened_at'] = listenedAt.millisecondsSinceEpoch ~/ 1000;
    }

    return payload;
  }

  void _queuePendingScrobble(Map<String, dynamic> payload) {
    _pendingScrobbles.add(payload);
    unawaited(_savePendingScrobbles());
    debugPrint('ListenBrainzService: Queued pending scrobble (${_pendingScrobbles.length} pending)');
  }

  /// Retry pending scrobbles (call when network is available)
  Future<int> retryPendingScrobbles() async {
    if (!_initialized || _config == null || _pendingScrobbles.isEmpty) {
      return 0;
    }

    debugPrint('ListenBrainzService: Retrying ${_pendingScrobbles.length} pending scrobbles');

    int successCount = 0;
    final failedScrobbles = <Map<String, dynamic>>[];
    final permanentFailures = <Map<String, dynamic>>[];

    for (final payload in _pendingScrobbles) {
      try {
        final response = await http.post(
          Uri.parse('$_baseUrl/submit-listens'),
          headers: {
            'Authorization': 'Token ${_config!.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'listen_type': 'single',
            'payload': [payload],
          }),
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          // Verify response body
          try {
            final responseData = jsonDecode(response.body);
            if (responseData['status'] == 'ok') {
              successCount++;
              continue;
            }
          } catch (_) {
            // Accept if we got 200 but couldn't parse
            successCount++;
            continue;
          }
          failedScrobbles.add(payload);
        } else if (response.statusCode >= 400 && response.statusCode < 500 && response.statusCode != 429) {
          // Permanent failure (bad request, auth error) - don't retry
          debugPrint('ListenBrainzService: Permanent failure for pending scrobble: ${response.statusCode}');
          permanentFailures.add(payload);
        } else {
          // Temporary failure - retry later
          failedScrobbles.add(payload);
        }
      } on TimeoutException {
        failedScrobbles.add(payload);
      } catch (e) {
        failedScrobbles.add(payload);
      }
    }

    // Only keep scrobbles that can be retried (not permanent failures)
    _pendingScrobbles = failedScrobbles;
    await _savePendingScrobbles();

    if (successCount > 0) {
      _config = _config!.copyWith(
        totalScrobbles: _config!.totalScrobbles + successCount,
        lastScrobbleTime: DateTime.now(),
      );
      await _saveConfig();
    }

    debugPrint('ListenBrainzService: Retried pending scrobbles: $successCount success, ${failedScrobbles.length} failed');
    return successCount;
  }

  /// Get personalized recommendations from ListenBrainz
  Future<List<ListenBrainzRecommendation>> getRecommendations({int count = 50}) async {
    if (!_initialized || _config == null) {
      debugPrint('ListenBrainzService: getRecommendations - not initialized or no config');
      return [];
    }
    debugPrint('ListenBrainzService: Fetching recommendations for ${_config!.username}...');

    const maxRetries = 3;
    const initialDelay = Duration(seconds: 1);

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final response = await http.get(
          Uri.parse('$_baseUrl/cf/recommendation/user/${_config!.username}/recording?count=$count'),
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final payload = data['payload'] as Map<String, dynamic>?;
          final mbids = payload?['mbids'] as List<dynamic>? ?? [];

          if (mbids.isEmpty) {
            debugPrint('ListenBrainzService: No recommendations yet - need more listening history (currently have ${_config?.totalScrobbles ?? 0} scrobbles, typically need 25-50+)');
            return [];
          }

          final recommendations = mbids.map((item) {
            if (item is Map<String, dynamic>) {
              return ListenBrainzRecommendation.fromJson(item);
            } else if (item is String) {
              return ListenBrainzRecommendation(recordingMbid: item, score: 0.0);
            }
            return null;
          }).whereType<ListenBrainzRecommendation>().toList();

          debugPrint('ListenBrainzService: Got ${recommendations.length} recommendations, fetching metadata...');

          // Fetch track/artist metadata from MusicBrainz for each recommendation
          final enrichedRecommendations = await _enrichRecommendationsWithMetadata(recommendations);
          debugPrint('ListenBrainzService: Enriched ${enrichedRecommendations.where((r) => r.trackName != null).length}/${recommendations.length} recommendations with metadata');
          return enrichedRecommendations;
        } else if (response.statusCode >= 500 || response.statusCode == 429) {
          // Server error or rate limit - retry with backoff
          debugPrint('ListenBrainzService: Recommendations failed: ${response.statusCode}, attempt ${attempt + 1}/$maxRetries');
          if (attempt < maxRetries - 1) {
            await Future.delayed(initialDelay * (1 << attempt));
            continue;
          }
        } else {
          // Client error - don't retry
          debugPrint('ListenBrainzService: Recommendations failed: ${response.statusCode}');
          return [];
        }
      } on TimeoutException {
        debugPrint('ListenBrainzService: Recommendations timeout, attempt ${attempt + 1}/$maxRetries');
        if (attempt < maxRetries - 1) {
          await Future.delayed(initialDelay * (1 << attempt));
          continue;
        }
      } catch (e) {
        // Network errors (connection reset, socket exception, etc.) - retry
        debugPrint('ListenBrainzService: Recommendations error: $e, attempt ${attempt + 1}/$maxRetries');
        if (attempt < maxRetries - 1) {
          await Future.delayed(initialDelay * (1 << attempt));
          continue;
        }
      }
    }

    debugPrint('ListenBrainzService: Recommendations failed after $maxRetries attempts');
    return [];
  }

  /// Fetch track/artist metadata from MusicBrainz for recommendations
  Future<List<ListenBrainzRecommendation>> _enrichRecommendationsWithMetadata(
    List<ListenBrainzRecommendation> recommendations,
  ) async {
    final enriched = <ListenBrainzRecommendation>[];
    int apiCallsMade = 0;

    for (int i = 0; i < recommendations.length; i++) {
      final rec = recommendations[i];

      // Skip if already has metadata
      if (rec.trackName != null && rec.artistName != null) {
        enriched.add(rec);
        continue;
      }

      // Check cache first
      final cached = _mbMetadataCache[rec.recordingMbid];
      if (cached != null) {
        enriched.add(ListenBrainzRecommendation(
          recordingMbid: rec.recordingMbid,
          trackName: cached['trackName'],
          artistName: cached['artistName'],
          albumName: cached['albumName'],
          releaseMbid: cached['releaseMbid'],
          score: rec.score,
        ));
        continue;
      }

      try {
        // Include releases to get album info for better matching
        final response = await http.get(
          Uri.parse('$_musicBrainzUrl/recording/${rec.recordingMbid}?fmt=json&inc=artist-credits+releases'),
          headers: {
            'User-Agent': 'Nautune/1.0 (https://github.com/elysiumdisc/nautune)',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final title = data['title'] as String?;
          final artistCredits = data['artist-credit'] as List<dynamic>?;
          final releases = data['releases'] as List<dynamic>?;

          String? artistName;
          if (artistCredits != null && artistCredits.isNotEmpty) {
            // Build artist name from credits (handles multiple artists)
            artistName = artistCredits.map((credit) {
              final artist = credit['artist'] as Map<String, dynamic>?;
              final joinPhrase = credit['joinphrase'] as String? ?? '';
              return '${artist?['name'] ?? ''}$joinPhrase';
            }).join();
          }

          // Get first album name and release ID for additional matching and album art
          String? albumName;
          String? releaseMbid;
          if (releases != null && releases.isNotEmpty) {
            albumName = releases.first['title'] as String?;
            releaseMbid = releases.first['id'] as String?;
          }

          // Cache the result (including releaseMbid for album art)
          if (title != null && artistName != null) {
            // Evict oldest entries if cache is full
            if (_mbMetadataCache.length >= _mbCacheMaxSize) {
              final keysToRemove = _mbMetadataCache.keys
                  .take(_mbMetadataCache.length - _mbCacheMaxSize + 20)
                  .toList();
              for (final key in keysToRemove) {
                _mbMetadataCache.remove(key);
              }
            }
            _mbMetadataCache[rec.recordingMbid] = {
              'trackName': title,
              'artistName': artistName,
              'albumName': ?albumName,
              'releaseMbid': ?releaseMbid,
            };
          }

          enriched.add(ListenBrainzRecommendation(
            recordingMbid: rec.recordingMbid,
            trackName: title,
            artistName: artistName,
            albumName: albumName,
            releaseMbid: releaseMbid,
            score: rec.score,
          ));
        } else if (response.statusCode == 429) {
          // Rate limited - wait longer and retry this one
          debugPrint('ListenBrainzService: MusicBrainz rate limited, waiting...');
          await Future.delayed(const Duration(seconds: 3));
          i--; // Retry this recommendation
          continue;
        } else {
          // Keep original recommendation without metadata
          enriched.add(rec);
        }

        apiCallsMade++;
      } catch (e) {
        // Keep original recommendation on error
        enriched.add(rec);
        debugPrint('ListenBrainzService: MusicBrainz lookup failed for ${rec.recordingMbid}: $e');
      }

      // MusicBrainz rate limit: strictly 1 request per second
      if (i < recommendations.length - 1 && apiCallsMade > 0) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    return enriched;
  }

  /// Match recommendations to tracks in Jellyfin library
  Future<List<ListenBrainzRecommendation>> matchRecommendationsToLibrary(
    List<ListenBrainzRecommendation> recommendations,
    JellyfinService jellyfin, {
    required String libraryId,
  }) async {
    final matchedRecommendations = <ListenBrainzRecommendation>[];

    for (final rec in recommendations) {
      bool matched = false;

      // Search by artist and track name
      if (rec.artistName != null && rec.trackName != null) {
        // Try searching by track name only for better results
        final tracks = await jellyfin.searchTracks(
          libraryId: libraryId,
          query: rec.trackName!,
        );

        if (tracks.isEmpty) {
          debugPrint('ListenBrainzService: No results for "${rec.trackName}"');
        } else {
          // Log first result for debugging
          final first = tracks.first;
          debugPrint('ListenBrainzService: "${rec.trackName}" -> ${tracks.length} results, first: "${first.name}" by ${first.artists}, MBID: ${first.providerIds?['MusicBrainzTrack']}');
        }

        // Find best match - prefer MBID match, fallback to name match
        for (final track in tracks) {
          // First priority: MusicBrainz ID match (most reliable)
          final trackMbid = track.providerIds?['MusicBrainzTrack'];
          final mbidMatch = trackMbid != null && trackMbid == rec.recordingMbid;

          if (mbidMatch) {
            matchedRecommendations.add(rec.withJellyfinMatch(track.id));
            matched = true;
            debugPrint('ListenBrainzService: ✓ MBID match for "${rec.trackName}"');
            break;
          }

          // Second priority: name + artist match (strict fuzzy)
          final recTrackLower = rec.trackName!.toLowerCase().trim();
          final recArtistLower = rec.artistName!.toLowerCase().trim();
          final trackNameLower = track.name.toLowerCase().trim();

          // Check if track names match — exact match, or contains only
          // if the shorter string is long enough to be meaningful (>= 8 chars)
          // to prevent short names like "Love" matching "I Love You Baby"
          final nameMatch = trackNameLower == recTrackLower ||
              (recTrackLower.length >= 8 && trackNameLower.contains(recTrackLower)) ||
              (trackNameLower.length >= 8 && recTrackLower.contains(trackNameLower));

          // Check if any artist matches (exact or contains with min length)
          final artistMatch = track.artists.any((a) {
            final artistLower = a.toLowerCase().trim();
            return artistLower == recArtistLower ||
                (recArtistLower.length >= 6 && artistLower.contains(recArtistLower)) ||
                (artistLower.length >= 6 && recArtistLower.contains(artistLower));
          });

          if (nameMatch && artistMatch) {
            matchedRecommendations.add(rec.withJellyfinMatch(track.id));
            matched = true;
            debugPrint('ListenBrainzService: ✓ Name match for "${rec.trackName}" -> "${track.name}"');
            break;
          }
        }
      }

      // Add unmatched recommendation too (for display)
      if (!matched) {
        matchedRecommendations.add(rec);
      }
    }

    final matchedCount = matchedRecommendations.where((r) => r.isInLibrary).length;
    debugPrint('ListenBrainzService: Matched $matchedCount/${recommendations.length} recommendations to library');

    return matchedRecommendations;
  }

  /// Get recommendations with matching - enriches and matches in batches
  /// Stops early when we have enough matches (more efficient for large counts)
  Future<List<ListenBrainzRecommendation>> getRecommendationsWithMatching({
    required JellyfinService jellyfin,
    required String libraryId,
    int targetMatches = 20,
    int maxFetch = 50,
  }) async {
    if (!_initialized || _config == null) {
      return [];
    }

    // Fetch raw recommendations (just MBIDs, fast)
    final rawRecs = await getRecommendations(count: maxFetch);
    if (rawRecs.isEmpty) return [];

    final allMatched = <ListenBrainzRecommendation>[];
    int matchCount = 0;
    const batchSize = 10;

    // Process in batches
    for (int batchStart = 0; batchStart < rawRecs.length; batchStart += batchSize) {
      final batchEnd = (batchStart + batchSize).clamp(0, rawRecs.length);
      final batch = rawRecs.sublist(batchStart, batchEnd);

      // Enrich batch with metadata
      final enrichedBatch = await _enrichRecommendationsWithMetadata(batch);

      // Match batch to library
      for (final rec in enrichedBatch) {
        if (rec.artistName == null || rec.trackName == null) {
          allMatched.add(rec);
          continue;
        }

        // Try multiple search strategies
        List<JellyfinTrack> tracks = await jellyfin.searchTracks(
          libraryId: libraryId,
          query: rec.trackName!,
        );

        // If no results by track name and we have album info, try album search
        if (tracks.isEmpty && rec.albumName != null) {
          tracks = await jellyfin.searchTracks(
            libraryId: libraryId,
            query: rec.albumName!,
          );
        }

        // Also try artist search if still no results
        if (tracks.isEmpty) {
          tracks = await jellyfin.searchTracks(
            libraryId: libraryId,
            query: rec.artistName!,
          );
        }

        // Try combined "artist track" query for better recall
        if (tracks.isEmpty) {
          tracks = await jellyfin.searchTracks(
            libraryId: libraryId,
            query: '${rec.artistName!} ${rec.trackName!}',
          );
        }

        bool matched = false;
        for (final track in tracks) {
          // MBID match
          final trackMbid = track.providerIds?['MusicBrainzTrack'];
          if (trackMbid != null && trackMbid == rec.recordingMbid) {
            allMatched.add(rec.withJellyfinMatch(track.id));
            matched = true;
            matchCount++;
            debugPrint('ListenBrainzService: ✓ MBID match for "${rec.trackName}"');
            break;
          }

          // Fuzzy name match (with .trim() and min length guards for consistency
          // with matchRecommendationsToLibrary)
          final recTrackLower = rec.trackName!.toLowerCase().trim();
          final recArtistLower = rec.artistName!.toLowerCase().trim();
          final trackNameLower = track.name.toLowerCase().trim();

          final nameMatch = trackNameLower == recTrackLower ||
              (recTrackLower.length >= 8 && trackNameLower.contains(recTrackLower)) ||
              (trackNameLower.length >= 8 && recTrackLower.contains(trackNameLower));

          final artistMatch = track.artists.any((a) {
            final artistLower = a.toLowerCase().trim();
            return artistLower == recArtistLower ||
                (recArtistLower.length >= 6 && artistLower.contains(recArtistLower)) ||
                (artistLower.length >= 6 && recArtistLower.contains(artistLower));
          });

          // Also check album match as additional criteria (with min length guards)
          final albumMatch = rec.albumName != null && track.album != null &&
              (track.album!.toLowerCase().trim() == rec.albumName!.toLowerCase().trim() ||
               (rec.albumName!.length >= 8 && track.album!.toLowerCase().trim().contains(rec.albumName!.toLowerCase().trim())) ||
               (track.album!.length >= 8 && rec.albumName!.toLowerCase().trim().contains(track.album!.toLowerCase().trim())));

          if (nameMatch && artistMatch) {
            allMatched.add(rec.withJellyfinMatch(track.id));
            matched = true;
            matchCount++;
            debugPrint('ListenBrainzService: ✓ Name match for "${rec.trackName}"');
            break;
          }

          // Allow album+track match without strict artist match (for compilations)
          if (nameMatch && albumMatch) {
            allMatched.add(rec.withJellyfinMatch(track.id));
            matched = true;
            matchCount++;
            debugPrint('ListenBrainzService: ✓ Album match for "${rec.trackName}" on "${track.album}"');
            break;
          }
        }

        if (!matched) {
          allMatched.add(rec);
        }
      }

      debugPrint('ListenBrainzService: Batch ${batchStart ~/ batchSize + 1}: $matchCount matches so far');

      // Early exit if we have enough matches
      if (matchCount >= targetMatches) {
        debugPrint('ListenBrainzService: Reached $targetMatches matches, stopping early');
        break;
      }
    }

    debugPrint('ListenBrainzService: Final: $matchCount matches from ${allMatched.length} processed');
    return allMatched;
  }

  /// Get user's recent listens from ListenBrainz
  Future<List<Map<String, dynamic>>> getRecentListens({int count = 25}) async {
    if (!_initialized || _config == null) {
      return [];
    }

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/user/${_config!.username}/listens?count=$count'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final payload = data['payload'] as Map<String, dynamic>?;
        final listens = payload?['listens'] as List<dynamic>? ?? [];
        return listens.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('ListenBrainzService: Recent listens error: $e');
      return [];
    }
  }

  // ===== POPULARITY API METHODS =====

  /// Get an artist's top tracks globally from ListenBrainz popularity API
  /// Endpoint: GET /1/popularity/top-recordings-for-artist/{artist_mbid}
  /// Note: This endpoint does not require authentication
  Future<List<PopularTrack>> getArtistTopTracks({
    required String artistMbid,
    int limit = 10,
  }) async {
    if (!_initialized) await initialize();
    if (artistMbid.isEmpty) return [];

    // Check cache first
    final cacheKey = 'artist_top_tracks_$artistMbid';
    final cached = _getPopularityCache<List<dynamic>>(cacheKey);
    if (cached != null) {
      debugPrint('ListenBrainzService: Using cached top tracks for artist $artistMbid');
      return cached
          .whereType<Map<String, dynamic>>()
          .map((json) => PopularTrack.fromJson(json))
          .take(limit)
          .toList();
    }

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/popularity/top-recordings-for-artist/$artistMbid'),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> recordings;

        // API can return list directly or wrapped in an object
        if (data is List) {
          recordings = data;
        } else if (data is Map && data['recordings'] is List) {
          recordings = data['recordings'] as List;
        } else {
          recordings = [];
        }

        // Cache the raw response
        if (recordings.isNotEmpty) {
          _setPopularityCache(cacheKey, recordings);
        }

        final tracks = recordings
            .whereType<Map<String, dynamic>>()
            .map((json) => PopularTrack.fromJson(json))
            .take(limit)
            .toList();

        debugPrint('ListenBrainzService: Got ${tracks.length} top tracks for artist $artistMbid');
        return tracks;
      } else {
        debugPrint('ListenBrainzService: Top tracks request failed: ${response.statusCode}');
        return [];
      }
    } on TimeoutException {
      debugPrint('ListenBrainzService: Top tracks request timed out');
      return [];
    } catch (e) {
      debugPrint('ListenBrainzService: Top tracks error: $e');
      return [];
    }
  }

  /// Batch lookup track popularity by recording MBIDs
  /// Endpoint: POST /1/popularity/recording
  /// Returns a map of recording MBID -> total listen count
  Future<Map<String, int>> getRecordingPopularities({
    required List<String> recordingMbids,
  }) async {
    if (!_initialized) await initialize();
    if (recordingMbids.isEmpty) return {};

    // Filter out empty MBIDs
    final validMbids = recordingMbids.where((m) => m.isNotEmpty).toList();
    if (validMbids.isEmpty) return {};

    // Check cache for each MBID and collect uncached ones
    final result = <String, int>{};
    final uncachedMbids = <String>[];

    for (final mbid in validMbids) {
      final cached = _getPopularityCache<int>('recording_popularity_$mbid');
      if (cached != null) {
        result[mbid] = cached;
      } else {
        uncachedMbids.add(mbid);
      }
    }

    if (uncachedMbids.isEmpty) {
      debugPrint('ListenBrainzService: All ${validMbids.length} recording popularities from cache');
      return result;
    }

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/popularity/recording'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'recording_mbids': uncachedMbids}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> recordings;

        if (data is List) {
          recordings = data;
        } else if (data is Map && data['recordings'] is List) {
          recordings = data['recordings'] as List;
        } else {
          recordings = [];
        }

        for (final item in recordings) {
          if (item is Map<String, dynamic>) {
            final mbid = item['recording_mbid'] as String?;
            final count = item['total_listen_count'];
            if (mbid != null && count != null) {
              final listenCount = (count is num) ? count.toInt() : 0;
              result[mbid] = listenCount;
              _setPopularityCache('recording_popularity_$mbid', listenCount);
            }
          }
        }

        debugPrint('ListenBrainzService: Got popularities for ${recordings.length} recordings');
        return result;
      } else {
        debugPrint('ListenBrainzService: Recording popularity request failed: ${response.statusCode}');
        return result;
      }
    } on TimeoutException {
      debugPrint('ListenBrainzService: Recording popularity request timed out');
      return result;
    } catch (e) {
      debugPrint('ListenBrainzService: Recording popularity error: $e');
      return result;
    }
  }

  /// Match popular tracks to Jellyfin library tracks
  Future<List<JellyfinTrack>> matchPopularTracksToLibrary({
    required List<PopularTrack> popularTracks,
    required JellyfinService jellyfin,
    required String libraryId,
    int maxResults = 5,
  }) async {
    final matched = <JellyfinTrack>[];

    for (final pop in popularTracks) {
      if (matched.length >= maxResults) break;

      JellyfinTrack? track;

      // Try searching by track name first
      if (pop.recordingName.isNotEmpty) {
        final tracks = await jellyfin.searchTracks(
          libraryId: libraryId,
          query: pop.recordingName,
        );

        // Primary match: MBID
        for (final t in tracks) {
          final trackMbid = t.providerIds?['MusicBrainzTrack'];
          if (trackMbid == pop.recordingMbid) {
            track = t;
            debugPrint('ListenBrainzService: ✓ MBID match for "${pop.recordingName}"');
            break;
          }
        }

        // Fallback: fuzzy name + artist match
        if (track == null && pop.artistName != null) {
          final popTrackLower = pop.recordingName.toLowerCase();
          final popArtistLower = pop.artistName!.toLowerCase();

          for (final t in tracks) {
            final trackNameLower = t.name.toLowerCase();
            final nameMatch = trackNameLower == popTrackLower ||
                trackNameLower.contains(popTrackLower) ||
                popTrackLower.contains(trackNameLower);

            final artistMatch = t.artists.any((a) {
              final aLower = a.toLowerCase();
              return aLower == popArtistLower ||
                  aLower.contains(popArtistLower) ||
                  popArtistLower.contains(aLower);
            });

            if (nameMatch && artistMatch) {
              track = t;
              debugPrint('ListenBrainzService: ✓ Name match for "${pop.recordingName}"');
              break;
            }
          }
        }
      }

      if (track != null && !matched.any((t) => t.id == track!.id)) {
        matched.add(track);
      }
    }

    debugPrint('ListenBrainzService: Matched ${matched.length}/$maxResults popular tracks to library');
    return matched;
  }

  // ===== POPULARITY CACHE HELPERS =====

  T? _getPopularityCache<T>(String key) {
    if (_popularityCacheBox == null) return null;

    try {
      final rawEntry = _popularityCacheBox!.get(key);
      if (rawEntry == null) return null;

      Map<String, dynamic> entry;
      if (rawEntry is String) {
        entry = Map<String, dynamic>.from(jsonDecode(rawEntry) as Map);
      } else if (rawEntry is Map) {
        entry = Map<String, dynamic>.from(rawEntry);
      } else {
        return null;
      }

      final timestamp = entry['timestamp'] as int?;
      if (timestamp == null) return null;

      final cachedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final age = DateTime.now().difference(cachedAt);
      if (age.inDays > _popularityCacheTtlDays) {
        // Expired
        _popularityCacheBox!.delete(key);
        return null;
      }

      return entry['data'] as T?;
    } catch (e) {
      debugPrint('ListenBrainzService: Cache read error for $key: $e');
      return null;
    }
  }

  void _setPopularityCache(String key, dynamic data) {
    if (_popularityCacheBox == null) return;

    try {
      final entry = {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      };
      _popularityCacheBox!.put(key, jsonEncode(entry));
    } catch (e) {
      debugPrint('ListenBrainzService: Cache write error for $key: $e');
    }
  }
}
