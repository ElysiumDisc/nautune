import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/jellyfin_user.dart';
import '../providers/session_provider.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  JellyfinUser? _user;

  // Stats
  List<JellyfinTrack>? _topTracks;
  List<JellyfinAlbum>? _topAlbums;
  List<JellyfinArtist>? _topArtists;
  List<JellyfinTrack>? _recentTracks;
  bool _statsLoading = true;

  // Additional Stats
  int _totalPlays = 0;
  double _totalHours = 0.0;
  List<Color>? _paletteColors;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadStats();
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

    try {
      // Fetch more tracks for better "Total" stats calculation
      final results = await Future.wait([
        appState.jellyfinService.getMostPlayedTracks(libraryId: libraryId, limit: 50),
        appState.jellyfinService.getMostPlayedAlbums(libraryId: libraryId, limit: 10),
        appState.jellyfinService.getMostPlayedArtists(libraryId: libraryId, limit: 10),
        appState.jellyfinService.getRecentlyPlayedTracks(libraryId: libraryId, limit: 10),
      ]);

      final tracks = results[0] as List<JellyfinTrack>;
      
      // Calculate totals
      int totalPlays = 0;
      int totalTicks = 0;
      for (final track in tracks) {
        final count = track.playCount ?? 0;
        totalPlays += count;
        if (track.runTimeTicks != null) {
          totalTicks += (track.runTimeTicks! * count);
        }
      }

      // Convert ticks to hours (1 tick = 100ns)
      final totalHours = totalTicks / (10000000 * 3600);

      if (mounted) {
        setState(() {
          _topTracks = tracks.take(5).toList();
          _topAlbums = results[1] as List<JellyfinAlbum>;
          _topArtists = results[2] as List<JellyfinArtist>;
          _recentTracks = results[3] as List<JellyfinTrack>;
          _totalPlays = totalPlays;
          _totalHours = totalHours;
          _statsLoading = false;
        });

        // Extract colors from top track
        if (tracks.isNotEmpty) {
          _extractColors(tracks.first);
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
                                              ),                        const SizedBox(height: 4),
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
                  // Quick stats cards
                  _buildQuickStatsRow(theme),
                  const SizedBox(height: 24),

                  // Top Tracks section
                  _buildSectionHeader(theme, 'Top Tracks', Icons.music_note),
                  const SizedBox(height: 12),
                  _buildTopTracksList(theme),
                  const SizedBox(height: 24),

                  // Top Artists section
                  _buildSectionHeader(theme, 'Top Artists', Icons.person),
                  const SizedBox(height: 12),
                  _buildTopArtistsList(theme),
                  const SizedBox(height: 24),

                  // Top Albums section
                  _buildSectionHeader(theme, 'Top Albums', Icons.album),
                  const SizedBox(height: 12),
                  _buildTopAlbumsList(theme),
                  const SizedBox(height: 24),

                  // Recently Played section
                  _buildSectionHeader(theme, 'Recently Played', Icons.history),
                  const SizedBox(height: 12),
                  _buildRecentlyPlayedList(theme),
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

  Widget _buildQuickStatsRow(ThemeData theme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                theme,
                icon: Icons.play_circle_outline,
                label: 'Total Plays',
                value: _totalPlays > 0 ? _totalPlays.toString() : '-',
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                theme,
                icon: Icons.timer_outlined,
                label: 'Hours',
                value: _totalHours > 0 ? _totalHours.toStringAsFixed(1) : '-',
                color: theme.colorScheme.secondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                theme,
                icon: Icons.person_outline,
                label: 'Top Artist',
                value: _topArtists?.isNotEmpty == true ? _topArtists!.first.name : '-',
                color: theme.colorScheme.tertiary,
                isSmallValue: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                theme,
                icon: Icons.album_outlined,
                label: 'Top Album',
                value: _topAlbums?.isNotEmpty == true ? _topAlbums!.first.name : '-',
                color: theme.colorScheme.error,
                isSmallValue: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    bool isSmallValue = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: (isSmallValue ? theme.textTheme.titleMedium : theme.textTheme.headlineSmall)?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
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
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _topArtists!.length,
        itemBuilder: (context, index) {
          final artist = _topArtists![index];
          final session = Provider.of<SessionProvider>(context, listen: false).session;
          final imageUrl = artist.primaryImageTag != null && session != null
              ? '${session.serverUrl}/Items/${artist.id}/Images/Primary?tag=${artist.primaryImageTag}'
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
                            placeholder: (context, url) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.person,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.person,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.person,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
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
              ],
            ),
          );
        },
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
      height: 160,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _topAlbums!.length,
        itemBuilder: (context, index) {
          final album = _topAlbums![index];
          final session = Provider.of<SessionProvider>(context, listen: false).session;
          final imageUrl = album.primaryImageTag != null && session != null
              ? '${session.serverUrl}/Items/${album.id}/Images/Primary?tag=${album.primaryImageTag}'
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
                    album.displayArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
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
}
