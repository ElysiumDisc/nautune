import 'dart:math';
import 'package:flutter/foundation.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';

/// Mood categories for smart playlist generation
enum Mood {
  chill,
  energetic,
  melancholy,
  upbeat;

  String get displayName {
    switch (this) {
      case Mood.chill:
        return 'Chill';
      case Mood.energetic:
        return 'Energetic';
      case Mood.melancholy:
        return 'Melancholy';
      case Mood.upbeat:
        return 'Upbeat';
    }
  }

  String get subtitle {
    switch (this) {
      case Mood.chill:
        return 'Jazz, Blues, Ambient...';
      case Mood.energetic:
        return 'Rock, EDM, Metal...';
      case Mood.melancholy:
        return 'Classical, Indie, Folk...';
      case Mood.upbeat:
        return 'Pop, Funk, Disco...';
    }
  }
}

/// Service for generating smart playlists based on genre-to-mood mapping
class SmartPlaylistService {
  final JellyfinService _jellyfinService;
  final String _libraryId;
  final Random _random = Random();

  SmartPlaylistService({
    required JellyfinService jellyfinService,
    required String libraryId,
  })  : _jellyfinService = jellyfinService,
        _libraryId = libraryId;

  /// Genre-to-mood mapping (case-insensitive matching)
  /// 100+ genres including subgenres, spelling variations, and abbreviations
  static const Map<String, Mood> _genreMoodMap = {
    // Chill genres
    'jazz': Mood.chill,
    'blues': Mood.chill,
    'ambient': Mood.chill,
    'lounge': Mood.chill,
    'bossa nova': Mood.chill,
    'bossa': Mood.chill,
    'chillout': Mood.chill,
    'chill out': Mood.chill,
    'chill-out': Mood.chill,
    'chill': Mood.chill,
    'downtempo': Mood.chill,
    'easy listening': Mood.chill,
    'soul': Mood.chill,
    'smooth jazz': Mood.chill,
    'trip hop': Mood.chill,
    'trip-hop': Mood.chill,
    'triphop': Mood.chill,
    'new age': Mood.chill,
    'world': Mood.chill,
    'lo-fi': Mood.chill,
    'lo fi': Mood.chill,
    'lofi': Mood.chill,
    'chillwave': Mood.chill,
    'neo-soul': Mood.chill,
    'neo soul': Mood.chill,
    'neosoul': Mood.chill,
    'soft rock': Mood.chill,
    'quiet storm': Mood.chill,
    'adult contemporary': Mood.chill,
    'spa': Mood.chill,
    'meditation': Mood.chill,
    'yoga': Mood.chill,
    'sleep': Mood.chill,
    'relaxation': Mood.chill,
    'smooth': Mood.chill,
    'acid jazz': Mood.chill,
    'fusion': Mood.chill,
    'bebop': Mood.chill,
    'cool jazz': Mood.chill,
    'free jazz': Mood.chill,
    'nu jazz': Mood.chill,
    'nu-jazz': Mood.chill,
    'dub': Mood.chill,
    'reggae dub': Mood.chill,
    'chillhop': Mood.chill,
    'chill hop': Mood.chill,

    // Energetic genres
    'rock': Mood.energetic,
    'metal': Mood.energetic,
    'heavy metal': Mood.energetic,
    'heavy': Mood.energetic,
    'punk': Mood.energetic,
    'punk rock': Mood.energetic,
    'electronic': Mood.energetic,
    'dance': Mood.energetic,
    'edm': Mood.energetic,
    'drum and bass': Mood.energetic,
    'drum & bass': Mood.energetic,
    'dnb': Mood.energetic,
    'd&b': Mood.energetic,
    'house': Mood.energetic,
    'techno': Mood.energetic,
    'hard rock': Mood.energetic,
    'alternative rock': Mood.energetic,
    'alternative': Mood.energetic,
    'alt': Mood.energetic,
    'alt rock': Mood.energetic,
    'alt-rock': Mood.energetic,
    'hardcore': Mood.energetic,
    'industrial': Mood.energetic,
    'trance': Mood.energetic,
    'dubstep': Mood.energetic,
    'grunge': Mood.energetic,
    'progressive rock': Mood.energetic,
    'prog rock': Mood.energetic,
    'prog': Mood.energetic,
    'progressive': Mood.energetic,
    'prog-rock': Mood.energetic,
    'psytrance': Mood.energetic,
    'psy trance': Mood.energetic,
    'psy-trance': Mood.energetic,
    'psychedelic trance': Mood.energetic,
    'goa': Mood.energetic,
    'goa trance': Mood.energetic,
    'metalcore': Mood.energetic,
    'metal core': Mood.energetic,
    'deathcore': Mood.energetic,
    'death metal': Mood.energetic,
    'black metal': Mood.energetic,
    'thrash metal': Mood.energetic,
    'thrash': Mood.energetic,
    'speed metal': Mood.energetic,
    'power metal': Mood.energetic,
    'nu metal': Mood.energetic,
    'nu-metal': Mood.energetic,
    'numetal': Mood.energetic,
    'rap metal': Mood.energetic,
    'rap rock': Mood.energetic,
    'post-punk': Mood.energetic,
    'post punk': Mood.energetic,
    'postpunk': Mood.energetic,
    'new wave': Mood.energetic,
    'garage rock': Mood.energetic,
    'garage': Mood.energetic,
    'noise rock': Mood.energetic,
    'noise': Mood.energetic,
    'math rock': Mood.energetic,
    'mathcore': Mood.energetic,
    'djent': Mood.energetic,
    'prog metal': Mood.energetic,
    'progressive metal': Mood.energetic,
    'symphonic metal': Mood.energetic,
    'folk metal': Mood.energetic,
    'viking metal': Mood.energetic,
    'doom metal': Mood.energetic,
    'stoner rock': Mood.energetic,
    'stoner metal': Mood.energetic,
    'sludge': Mood.energetic,
    'sludge metal': Mood.energetic,
    'crossover': Mood.energetic,
    'crossover thrash': Mood.energetic,
    'hardcore punk': Mood.energetic,
    'post-hardcore': Mood.energetic,
    'post hardcore': Mood.energetic,
    'screamo': Mood.energetic,
    'emo': Mood.energetic,
    'pop punk': Mood.energetic,
    'pop-punk': Mood.energetic,
    'skate punk': Mood.energetic,
    'electro': Mood.energetic,
    'electronica': Mood.energetic,
    'big beat': Mood.energetic,
    'breakbeat': Mood.energetic,
    'breaks': Mood.energetic,
    'jungle': Mood.energetic,
    'hardstyle': Mood.energetic,
    'hard dance': Mood.energetic,
    'gabber': Mood.energetic,
    'speedcore': Mood.energetic,
    'uk garage': Mood.energetic,
    'uk bass': Mood.energetic,
    'bass music': Mood.energetic,
    'brostep': Mood.energetic,
    'riddim': Mood.energetic,
    'trap': Mood.energetic,
    'edm trap': Mood.energetic,
    'future bass': Mood.energetic,
    'complextro': Mood.energetic,
    'moombahton': Mood.energetic,
    'glitch': Mood.energetic,
    'glitch hop': Mood.energetic,
    'midtempo': Mood.energetic,

    // Melancholy genres
    'classical': Mood.melancholy,
    'indie': Mood.melancholy,
    'folk': Mood.melancholy,
    'acoustic': Mood.melancholy,
    'singer-songwriter': Mood.melancholy,
    'singer songwriter': Mood.melancholy,
    'sad': Mood.melancholy,
    'piano': Mood.melancholy,
    'orchestral': Mood.melancholy,
    'soundtrack': Mood.melancholy,
    'ost': Mood.melancholy,
    'score': Mood.melancholy,
    'film score': Mood.melancholy,
    'instrumental': Mood.melancholy,
    'chamber': Mood.melancholy,
    'baroque': Mood.melancholy,
    'romantic': Mood.melancholy,
    'post-rock': Mood.melancholy,
    'post rock': Mood.melancholy,
    'postrock': Mood.melancholy,
    'shoegaze': Mood.melancholy,
    'dream pop': Mood.melancholy,
    'dreampop': Mood.melancholy,
    'slowcore': Mood.melancholy,
    'dark ambient': Mood.melancholy,
    'darkwave': Mood.melancholy,
    'dark wave': Mood.melancholy,
    'gothic': Mood.melancholy,
    'goth': Mood.melancholy,
    'gothic rock': Mood.melancholy,
    'coldwave': Mood.melancholy,
    'ethereal': Mood.melancholy,
    'ethereal wave': Mood.melancholy,
    'indie folk': Mood.melancholy,
    'indie-folk': Mood.melancholy,
    'chamber pop': Mood.melancholy,
    'chamber folk': Mood.melancholy,
    'americana': Mood.melancholy,
    'country': Mood.melancholy,
    'bluegrass': Mood.melancholy,
    'celtic': Mood.melancholy,
    'irish': Mood.melancholy,
    'traditional': Mood.melancholy,
    'minimal': Mood.melancholy,
    'minimalism': Mood.melancholy,
    'minimalist': Mood.melancholy,
    'contemporary classical': Mood.melancholy,
    'modern classical': Mood.melancholy,
    'neoclassical': Mood.melancholy,
    'neo-classical': Mood.melancholy,
    'ambient electronic': Mood.melancholy,
    'drone': Mood.melancholy,
    'experimental': Mood.melancholy,
    'avant-garde': Mood.melancholy,
    'avant garde': Mood.melancholy,
    'art rock': Mood.melancholy,
    'art pop': Mood.melancholy,
    'ballad': Mood.melancholy,
    'ballads': Mood.melancholy,

    // Upbeat genres
    'pop': Mood.upbeat,
    'funk': Mood.upbeat,
    'disco': Mood.upbeat,
    'r&b': Mood.upbeat,
    'rnb': Mood.upbeat,
    'r and b': Mood.upbeat,
    'rhythm and blues': Mood.upbeat,
    'reggae': Mood.upbeat,
    'latin': Mood.upbeat,
    'hip hop': Mood.upbeat,
    'hip-hop': Mood.upbeat,
    'hiphop': Mood.upbeat,
    'rap': Mood.upbeat,
    'k-pop': Mood.upbeat,
    'kpop': Mood.upbeat,
    'k pop': Mood.upbeat,
    'j-pop': Mood.upbeat,
    'jpop': Mood.upbeat,
    'j pop': Mood.upbeat,
    'c-pop': Mood.upbeat,
    'cpop': Mood.upbeat,
    'ska': Mood.upbeat,
    'motown': Mood.upbeat,
    'afrobeat': Mood.upbeat,
    'afrobeats': Mood.upbeat,
    'afro': Mood.upbeat,
    'salsa': Mood.upbeat,
    'samba': Mood.upbeat,
    'cumbia': Mood.upbeat,
    'dancehall': Mood.upbeat,
    'electropop': Mood.upbeat,
    'electro pop': Mood.upbeat,
    'synth-pop': Mood.upbeat,
    'synthpop': Mood.upbeat,
    'synth pop': Mood.upbeat,
    'nu-disco': Mood.upbeat,
    'nu disco': Mood.upbeat,
    'nudisco': Mood.upbeat,
    'dance-pop': Mood.upbeat,
    'dance pop': Mood.upbeat,
    'dancepop': Mood.upbeat,
    'bubblegum': Mood.upbeat,
    'bubblegum pop': Mood.upbeat,
    'teen pop': Mood.upbeat,
    'euro pop': Mood.upbeat,
    'europop': Mood.upbeat,
    'eurodance': Mood.upbeat,
    'italo disco': Mood.upbeat,
    'hi-nrg': Mood.upbeat,
    'hi nrg': Mood.upbeat,
    'high energy': Mood.upbeat,
    'new jack swing': Mood.upbeat,
    'g-funk': Mood.upbeat,
    'g funk': Mood.upbeat,
    'bounce': Mood.upbeat,
    'crunk': Mood.upbeat,
    'hyphy': Mood.upbeat,
    'snap': Mood.upbeat,
    'southern hip hop': Mood.upbeat,
    'east coast hip hop': Mood.upbeat,
    'west coast hip hop': Mood.upbeat,
    'conscious hip hop': Mood.upbeat,
    'boom bap': Mood.upbeat,
    'gangsta rap': Mood.upbeat,
    'reggaeton': Mood.upbeat,
    'dembow': Mood.upbeat,
    'latin pop': Mood.upbeat,
    'latin urban': Mood.upbeat,
    'bachata': Mood.upbeat,
    'merengue': Mood.upbeat,
    'tango': Mood.upbeat,
    'boogaloo': Mood.upbeat,
    'mambo': Mood.upbeat,
    'cha cha': Mood.upbeat,
    'tropical': Mood.upbeat,
    'tropical house': Mood.upbeat,
    'deep house': Mood.upbeat,
    'tech house': Mood.upbeat,
    'progressive house': Mood.upbeat,
    'electro house': Mood.upbeat,
    'big room': Mood.upbeat,
    'festival': Mood.upbeat,
    'vocal trance': Mood.upbeat,
    'uplifting trance': Mood.upbeat,
    'happy hardcore': Mood.upbeat,
    'nightcore': Mood.upbeat,
    'uk funky': Mood.upbeat,
    'grime': Mood.upbeat,
    'uk drill': Mood.upbeat,
    'drill': Mood.upbeat,
    'phonk': Mood.upbeat,
    'hyperpop': Mood.upbeat,
    'hyper pop': Mood.upbeat,
    'pc music': Mood.upbeat,
    'glitchpop': Mood.upbeat,
    'indie pop': Mood.upbeat,
    'indie-pop': Mood.upbeat,
    'jangle pop': Mood.upbeat,
    'power pop': Mood.upbeat,
    'britpop': Mood.upbeat,
    'brit pop': Mood.upbeat,
    'brit-pop': Mood.upbeat,
    'j-rock': Mood.upbeat,
    'jrock': Mood.upbeat,
    'visual kei': Mood.upbeat,
    'k-rock': Mood.upbeat,
    'krock': Mood.upbeat,
    'city pop': Mood.upbeat,
    'citypop': Mood.upbeat,
  };

  /// Get the mood for a given genre (case-insensitive)
  Mood? getMoodForGenre(String genre) {
    final normalized = genre.toLowerCase().trim();
    return _genreMoodMap[normalized];
  }

  /// Try to detect mood from tags (preferred over genre mapping)
  /// Looks for mood-related keywords in the track's tags
  Mood? _getMoodFromTags(JellyfinTrack track) {
    final tags = track.tags;
    if (tags == null || tags.isEmpty) return null;

    for (final tag in tags) {
      final normalized = tag.toLowerCase().trim();

      // Check for chill-related keywords
      if (normalized.contains('chill') ||
          normalized.contains('relaxed') ||
          normalized.contains('calm') ||
          normalized.contains('mellow') ||
          normalized.contains('peaceful') ||
          normalized.contains('ambient')) {
        return Mood.chill;
      }

      // Check for energetic-related keywords
      if (normalized.contains('energetic') ||
          normalized.contains('energy') ||
          normalized.contains('intense') ||
          normalized.contains('powerful') ||
          normalized.contains('driving') ||
          normalized.contains('aggressive')) {
        return Mood.energetic;
      }

      // Check for melancholy-related keywords
      if (normalized.contains('melancholy') ||
          normalized.contains('sad') ||
          normalized.contains('emotional') ||
          normalized.contains('somber') ||
          normalized.contains('moody') ||
          normalized.contains('dark')) {
        return Mood.melancholy;
      }

      // Check for upbeat-related keywords
      if (normalized.contains('upbeat') ||
          normalized.contains('happy') ||
          normalized.contains('cheerful') ||
          normalized.contains('fun') ||
          normalized.contains('party') ||
          normalized.contains('groovy')) {
        return Mood.upbeat;
      }
    }

    return null;
  }

  /// Analyze a track's primary mood based on its genres (fallback method)
  Mood? _getMoodFromGenres(JellyfinTrack track) {
    final genres = track.genres;
    if (genres == null || genres.isEmpty) return null;

    // Count mood occurrences across all genres
    final moodCounts = <Mood, int>{};
    for (final genre in genres) {
      final mood = getMoodForGenre(genre);
      if (mood != null) {
        moodCounts[mood] = (moodCounts[mood] ?? 0) + 1;
      }
    }

    if (moodCounts.isEmpty) return null;

    // Return the mood with the highest count
    return moodCounts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
  }

  /// Get mood from actual tags (preferred) or fall back to genre mapping
  Mood? getTrackMood(JellyfinTrack track) {
    // First check actual tags for mood keywords
    final tagMood = _getMoodFromTags(track);
    if (tagMood != null) return tagMood;

    // Fall back to existing genre-based mapping
    return _getMoodFromGenres(track);
  }

  /// Get all tracks that match a specific mood
  Future<List<JellyfinTrack>> getTracksByMood(Mood mood, {int limit = 50}) async {
    try {
      debugPrint('SmartPlaylist: Fetching tracks for libraryId: $_libraryId');

      // Get all tracks from the library
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      debugPrint('SmartPlaylist: Fetched ${allTracks.length} total tracks');

      // Debug: Check how many tracks have genres
      final tracksWithGenres = allTracks.where((t) => t.genres != null && t.genres!.isNotEmpty).length;
      final tracksWithTags = allTracks.where((t) => t.tags != null && t.tags!.isNotEmpty).length;
      debugPrint('SmartPlaylist: $tracksWithGenres tracks have genres, $tracksWithTags have tags');

      // Debug: Show some sample genres
      if (allTracks.isNotEmpty) {
        final sampleGenres = <String>{};
        for (final track in allTracks.take(50)) {
          if (track.genres != null) {
            sampleGenres.addAll(track.genres!);
          }
        }
        if (sampleGenres.isNotEmpty) {
          debugPrint('SmartPlaylist: Sample genres: ${sampleGenres.take(10).join(', ')}');
        }
      }

      // Filter by mood
      final matchingTracks = <JellyfinTrack>[];
      for (final track in allTracks) {
        final trackMood = getTrackMood(track);
        if (trackMood == mood) {
          matchingTracks.add(track);
        }
      }

      debugPrint('SmartPlaylist: Found ${matchingTracks.length} tracks for mood ${mood.displayName}');

      // Shuffle and limit
      matchingTracks.shuffle(_random);
      if (matchingTracks.length > limit) {
        return matchingTracks.sublist(0, limit);
      }

      return matchingTracks;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting tracks by mood: $e');
      return [];
    }
  }

  /// Generate a shuffled mood mix playlist
  Future<List<JellyfinTrack>> generateMoodMix(Mood mood, {int limit = 50}) async {
    final tracks = await getTracksByMood(mood, limit: limit);
    debugPrint('SmartPlaylist: Generated ${mood.displayName} mix with ${tracks.length} tracks');
    return tracks;
  }

  /// Check if any tracks are available for a mood
  Future<bool> hasMoodTracks(Mood mood) async {
    final tracks = await getTracksByMood(mood, limit: 1);
    return tracks.isNotEmpty;
  }

  /// Get track counts for all moods (for UI display)
  Future<Map<Mood, int>> getMoodTrackCounts() async {
    try {
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      final counts = <Mood, int>{};

      for (final track in allTracks) {
        final mood = getTrackMood(track);
        if (mood != null) {
          counts[mood] = (counts[mood] ?? 0) + 1;
        }
      }

      return counts;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting mood counts: $e');
      return {};
    }
  }

  // ============ Tag-based filtering methods ============

  /// Get tracks by specific tag (case-insensitive partial match)
  Future<List<JellyfinTrack>> getTracksByTag(String tag, {int limit = 50}) async {
    try {
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      final normalizedTag = tag.toLowerCase();

      final matchingTracks = allTracks
          .where((track) =>
              track.tags?.any((t) => t.toLowerCase().contains(normalizedTag)) ?? false)
          .toList();

      debugPrint('SmartPlaylist: Found ${matchingTracks.length} tracks for tag "$tag"');

      // Shuffle and limit
      matchingTracks.shuffle(_random);
      if (matchingTracks.length > limit) {
        return matchingTracks.sublist(0, limit);
      }

      return matchingTracks;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting tracks by tag: $e');
      return [];
    }
  }

  /// Get tracks that have ANY of the specified tags
  Future<List<JellyfinTrack>> getTracksByAnyTag(List<String> tags, {int limit = 50}) async {
    try {
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      final normalizedTags = tags.map((t) => t.toLowerCase()).toSet();

      final matchingTracks = allTracks.where((track) {
        final trackTags = track.tags;
        if (trackTags == null || trackTags.isEmpty) return false;
        return trackTags.any((t) =>
            normalizedTags.any((nt) => t.toLowerCase().contains(nt)));
      }).toList();

      debugPrint('SmartPlaylist: Found ${matchingTracks.length} tracks for tags $tags');

      // Shuffle and limit
      matchingTracks.shuffle(_random);
      if (matchingTracks.length > limit) {
        return matchingTracks.sublist(0, limit);
      }

      return matchingTracks;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting tracks by tags: $e');
      return [];
    }
  }

  /// Get tracks that have ALL of the specified tags
  Future<List<JellyfinTrack>> getTracksByAllTags(List<String> tags, {int limit = 50}) async {
    try {
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      final normalizedTags = tags.map((t) => t.toLowerCase()).toList();

      final matchingTracks = allTracks.where((track) {
        final trackTags = track.tags;
        if (trackTags == null || trackTags.isEmpty) return false;
        final trackTagsNormalized = trackTags.map((t) => t.toLowerCase()).toList();
        return normalizedTags.every((nt) =>
            trackTagsNormalized.any((tt) => tt.contains(nt)));
      }).toList();

      debugPrint('SmartPlaylist: Found ${matchingTracks.length} tracks with all tags $tags');

      // Shuffle and limit
      matchingTracks.shuffle(_random);
      if (matchingTracks.length > limit) {
        return matchingTracks.sublist(0, limit);
      }

      return matchingTracks;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting tracks by all tags: $e');
      return [];
    }
  }

  /// Get all unique tags in library (for filter UI)
  Future<Set<String>> getAllTags() async {
    try {
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      final tags = <String>{};

      for (final track in allTracks) {
        final trackTags = track.tags;
        if (trackTags != null && trackTags.isNotEmpty) {
          tags.addAll(trackTags);
        }
      }

      debugPrint('SmartPlaylist: Found ${tags.length} unique tags in library');
      return tags;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting all tags: $e');
      return {};
    }
  }

  /// Get tag counts (how many tracks have each tag)
  Future<Map<String, int>> getTagCounts() async {
    try {
      final allTracks = await _jellyfinService.getAllTracks(libraryId: _libraryId);
      final counts = <String, int>{};

      for (final track in allTracks) {
        final trackTags = track.tags;
        if (trackTags != null) {
          for (final tag in trackTags) {
            counts[tag] = (counts[tag] ?? 0) + 1;
          }
        }
      }

      return counts;
    } catch (e) {
      debugPrint('SmartPlaylist: Error getting tag counts: $e');
      return {};
    }
  }

  /// Check if any tracks have the specified tag
  Future<bool> hasTaggedTracks(String tag) async {
    final tracks = await getTracksByTag(tag, limit: 1);
    return tracks.isNotEmpty;
  }
}
