import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../jellyfin/jellyfin_track.dart';

/// A bottom sheet that displays detailed metadata for a track.
class TrackInfoSheet extends StatelessWidget {
  const TrackInfoSheet({super.key, required this.track});

  final JellyfinTrack track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            Text(
              track.name,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (track.artists.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  track.displayArtist,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 16),

            // Audio Quality section
            if (_hasAudioInfo) ...[
              _SectionHeader(title: 'Audio Quality', theme: theme),
              _buildQualityBadge(theme),
              if (track.codec != null)
                _InfoRow(label: 'Codec', value: track.codec!),
              if (track.container != null)
                _InfoRow(label: 'Container', value: track.container!),
              if (track.bitrate != null)
                _InfoRow(
                  label: 'Bitrate',
                  value: '${(track.bitrate! / 1000).round()} kbps',
                ),
              if (track.sampleRate != null)
                _InfoRow(
                  label: 'Sample Rate',
                  value: '${(track.sampleRate! / 1000).toStringAsFixed(1)} kHz',
                ),
              if (track.bitDepth != null)
                _InfoRow(label: 'Bit Depth', value: '${track.bitDepth}-bit'),
              if (track.channels != null)
                _InfoRow(label: 'Channels', value: _channelLabel(track.channels!)),
              const SizedBox(height: 16),
            ],

            // Track Info section
            _SectionHeader(title: 'Track Info', theme: theme),
            _InfoRow(label: 'Title', value: track.name),
            if (track.album != null)
              _InfoRow(label: 'Album', value: track.album!),
            if (track.artists.isNotEmpty)
              _InfoRow(label: 'Artist', value: track.displayArtist),
            if (track.indexNumber != null)
              _InfoRow(label: 'Track #', value: '${track.indexNumber}'),
            if (track.parentIndexNumber != null)
              _InfoRow(label: 'Disc #', value: '${track.parentIndexNumber}'),
            if (track.runTimeTicks != null)
              _InfoRow(
                label: 'Duration',
                value: _formatDuration(
                  Duration(microseconds: track.runTimeTicks! ~/ 10),
                ),
              ),
            if (track.genres != null && track.genres!.isNotEmpty)
              _InfoRow(label: 'Genres', value: track.genres!.join(', ')),
            if (track.playCount != null)
              _InfoRow(label: 'Play Count', value: '${track.playCount}'),
            const SizedBox(height: 16),

            // External IDs section
            if (track.providerIds != null && track.providerIds!.isNotEmpty) ...[
              _SectionHeader(title: 'External IDs', theme: theme),
              ...track.providerIds!.entries.map(
                (entry) => _InfoRow(
                  label: _formatProviderId(entry.key),
                  value: entry.value,
                  copyable: true,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  bool get _hasAudioInfo =>
      track.codec != null ||
      track.container != null ||
      track.bitrate != null ||
      track.sampleRate != null ||
      track.bitDepth != null ||
      track.channels != null;

  Widget _buildQualityBadge(ThemeData theme) {
    final qualityInfo = track.audioQualityInfo;
    if (qualityInfo == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          qualityInfo,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  String _channelLabel(int channels) {
    switch (channels) {
      case 1:
        return 'Mono';
      case 2:
        return 'Stereo';
      case 6:
        return '5.1 Surround';
      case 8:
        return '7.1 Surround';
      default:
        return '$channels channels';
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatProviderId(String key) {
    // Convert "MusicBrainzTrack" -> "MusicBrainz Track"
    return key.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.theme});

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: copyable
                ? GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Copied: $value'),
                          duration: const Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            value,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.copy,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  )
                : Text(
                    value,
                    style: theme.textTheme.bodyMedium,
                  ),
          ),
        ],
      ),
    );
  }
}
