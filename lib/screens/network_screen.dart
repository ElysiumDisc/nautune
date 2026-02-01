import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/network_channels.dart';
import '../models/network_channel.dart';
import '../providers/connectivity_provider.dart';
import '../providers/demo_mode_provider.dart';
import '../services/listening_analytics_service.dart';
import '../services/network_download_service.dart';

/// Network easter egg screen - mimics other-people.network radio interface.
/// Online-only feature for streaming radio shows from Nicolas Jaar's Other People label.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final TextEditingController _channelController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  NetworkChannel? _currentChannel;
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _isLoading = false;
  String? _errorMessage;

  // Download service
  late NetworkDownloadService _downloadService;

  // Listening time tracking
  DateTime? _playStartTime;

  // Ticker animation for scrolling text
  late AnimationController _tickerController;

  @override
  void initState() {
    super.initState();
    _downloadService = NetworkDownloadService();

    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();

    // Listen to player state changes
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        final wasPlaying = _isPlaying;
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });

        // Track listening time
        if (_isPlaying && !wasPlaying) {
          // Started playing
          _playStartTime = DateTime.now();
        } else if (!_isPlaying && wasPlaying) {
          // Stopped playing
          _recordListenTime();
        }
      }
    });

    // Listen for errors (only log actual errors, not spam)
    _audioPlayer.onLog.listen((msg) {
      if (!msg.contains('Could not query')) {
        debugPrint('AudioPlayer: $msg');
      }
    });

    // Listen to download service changes
    _downloadService.addListener(_onDownloadServiceChanged);

    // Mark Network easter egg as discovered for the milestone
    _markDiscovered();
  }

  void _markDiscovered() {
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized) {
      analytics.markNetworkDiscovered();
    }
  }

  void _onDownloadServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // Record any remaining listen time before disposing
    _recordListenTime();
    _tickerController.dispose();
    _audioPlayer.dispose();
    _channelController.dispose();
    _scrollController.dispose();
    _downloadService.removeListener(_onDownloadServiceChanged);
    super.dispose();
  }

  /// Record listening time for the current channel.
  void _recordListenTime() {
    if (_currentChannel != null && _playStartTime != null) {
      final seconds = DateTime.now().difference(_playStartTime!).inSeconds;
      if (seconds > 0) {
        _downloadService.recordListenTime(_currentChannel!.number, seconds);
      }
      _playStartTime = null;
    }
  }

  Future<void> _tuneToChannel(int channelNumber) async {
    // Record listening time for previous channel before switching
    _recordListenTime();

    // Clamp to valid range
    final clampedNumber = channelNumber.clamp(0, 333);
    final channel = findNearestChannel(clampedNumber);

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _audioPlayer.stop();

      // Get playback URL (local if downloaded, stream otherwise)
      final playbackUrl = await _downloadService.getPlaybackUrl(channel);
      final isLocal = playbackUrl.startsWith('/') || playbackUrl.startsWith('file://');

      debugPrint('📻 Network Radio: Tuning to channel ${channel.number}');
      debugPrint('📻 Channel: ${channel.name} by ${channel.artist}');
      debugPrint('📻 Audio file: ${channel.audioFile}');
      debugPrint('📻 ${isLocal ? "Playing LOCAL" : "Streaming"}: $playbackUrl');

      // Check if it's a local file or URL
      if (isLocal) {
        await _audioPlayer.setSourceDeviceFile(playbackUrl);
      } else {
        await _audioPlayer.setSourceUrl(playbackUrl);
      }

      await _audioPlayer.setVolume(_isMuted ? 0.0 : 1.0);
      await _audioPlayer.resume();

      setState(() {
        _currentChannel = channel;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to tune to channel $clampedNumber';
      });
      debugPrint('Network radio error: $e');
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _audioPlayer.setVolume(_isMuted ? 0.0 : 1.0);
  }

  void _onSubmitChannel() {
    final text = _channelController.text.trim();
    if (text.isEmpty) return;

    final number = int.tryParse(text);
    if (number != null) {
      _tuneToChannel(number);
      _channelController.clear();
      FocusScope.of(context).unfocus();
    }
  }

  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _buildSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connectivity = context.watch<ConnectivityProvider>();
    final demoMode = context.watch<DemoModeProvider>();
    final isOffline = !connectivity.networkAvailable || demoMode.isDemoMode;
    final hasDownloads = _downloadService.downloadedCount > 0;

    // Show offline/demo message only if no downloads available
    if (isOffline && !hasDownloads) {
      final message = demoMode.isDemoMode
          ? 'DEMO MODE\n\nDownload channels while online\nto access them in demo mode'
          : 'THE NETWORK REQUIRES\nAN INTERNET CONNECTION\n\nDownload channels from Settings\nto access them offline';
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: _buildAppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 14,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            // Header section with current channel info
            _buildHeader(),

            // Main content
            Expanded(
              child: _buildMainContent(isOffline),
            ),

            // Footer
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          _audioPlayer.stop();
          Navigator.of(context).pop();
        },
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Download status indicator
          if (_downloadService.downloadedCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: _downloadService.isDownloadingAny
                    ? Colors.blue.withValues(alpha: 0.3)
                    : Colors.green.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _downloadService.isDownloadingAny
                        ? Icons.downloading
                        : Icons.download_done,
                    size: 12,
                    color: _downloadService.isDownloadingAny
                        ? Colors.blue
                        : Colors.green,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${_downloadService.downloadedCount}/${networkChannels.length}',
                    style: TextStyle(
                      color: _downloadService.isDownloadingAny
                          ? Colors.blue
                          : Colors.green,
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        // Mute button - Other People Network symbol
        GestureDetector(
          onTap: _toggleMute,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Opacity(
              opacity: _isMuted ? 0.3 : 1.0,
              child: Image.asset(
                'assets/images/network_symbol.png',
                width: 32,
                height: 32,
                color: Colors.white,
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
          ),
        ),
        // Settings button
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: _showSettingsSheet,
        ),
      ],
    );
  }

  Widget _buildSettingsSheet() {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        // Calculate download progress
        final totalChannels = networkChannels.length;
        final downloadedCount = _downloadService.downloadedCount;
        final isDownloading = _downloadService.isDownloadingAny;
        final downloadingCount = _downloadService.downloadingCount;
        final progress = totalChannels > 0 ? downloadedCount / totalChannels : 0.0;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              const Text(
                'NETWORK DOWNLOADS',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 16,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),

              // Download all section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '$downloadedCount / $totalChannels channels',
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '${(progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: Colors.green,
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.grey[800],
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDownloading ? Colors.blue : Colors.green,
                        ),
                        minHeight: 8,
                      ),
                    ),
                    if (isDownloading) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Downloading $downloadingCount channel${downloadingCount > 1 ? 's' : ''}...',
                        style: const TextStyle(
                          color: Colors.blue,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: downloadedCount >= totalChannels
                                ? null
                                : () async {
                                    await _downloadService.downloadAllChannels();
                                    setSheetState(() {});
                                    setState(() {});
                                  },
                            icon: Icon(
                              downloadedCount >= totalChannels
                                  ? Icons.check_circle
                                  : Icons.download,
                              size: 18,
                            ),
                            label: Text(
                              downloadedCount >= totalChannels
                                  ? 'ALL DOWNLOADED'
                                  : 'DOWNLOAD ALL',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                letterSpacing: 1,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: downloadedCount >= totalChannels
                                  ? Colors.green
                                  : Colors.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        if (isDownloading) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () {
                              _downloadService.cancelAllDownloads();
                              setSheetState(() {});
                              setState(() {});
                            },
                            icon: const Icon(Icons.stop, color: Colors.red),
                            tooltip: 'Cancel downloads',
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Storage info
              FutureBuilder<NetworkStorageStats>(
                future: _downloadService.getStorageStats(),
                builder: (context, snapshot) {
                  final stats = snapshot.data;
                  final downloadedChannels = _downloadService.downloadedChannels;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Storage Used',
                          style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          stats != null
                              ? '${stats.formattedTotal} (${stats.formattedAudio} audio, ${stats.formattedImages} images)'
                              : 'Calculating...',
                          style: const TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 12),
                        ),
                        trailing: stats != null && stats.channelCount > 0
                            ? TextButton(
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      backgroundColor: Colors.grey[900],
                                      title: const Text(
                                        'Delete All Downloads?',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      content: Text(
                                        'This will remove ${stats.channelCount} downloaded channels (${stats.formattedTotal})',
                                        style: const TextStyle(color: Colors.white70),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(context, true),
                                          child: const Text('Delete', style: TextStyle(color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await _downloadService.deleteAllChannels();
                                    setSheetState(() {});
                                    setState(() {});
                                  }
                                },
                                child: const Text(
                                  'Clear All',
                                  style: TextStyle(color: Colors.red, fontFamily: 'monospace'),
                                ),
                              )
                            : null,
                      ),

                      // Show list of downloaded channels
                      if (downloadedChannels.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 150),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white24),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: downloadedChannels.length,
                            itemBuilder: (context, index) {
                              final channel = downloadedChannels[index];
                              return ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                                leading: Text(
                                  '${channel.number}'.padLeft(3, '0'),
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                title: Text(
                                  channel.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  channel.artist,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                  ),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                                  onPressed: () async {
                                    await _downloadService.deleteChannel(channel.number);
                                    setSheetState(() {});
                                    setState(() {});
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ] else ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No channels downloaded yet. Tap "Download All" to save all channels for offline listening.',
                            style: TextStyle(
                              color: Colors.white38,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),

              const Divider(color: Colors.white24),

              // Credits link
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Credits',
                  style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
                ),
                subtitle: const Text(
                  'www.other-people.network',
                  style: TextStyle(color: Colors.white54, fontFamily: 'monospace', fontSize: 12),
                ),
                trailing: const Icon(Icons.open_in_new, color: Colors.white54, size: 16),
                onTap: () {
                  // Show credits dialog
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: Colors.grey[900],
                      title: const Text(
                        'Other People Network',
                        style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
                      ),
                      content: const SingleChildScrollView(
                        child: Text(
                          'A project by Nicolas Jaar and the Other People label.\n\n'
                          'Programming: Cole Brown\n'
                          'Design: Cole Brown, Against All Logic\n'
                          'Artists: Jena Myung, Maziyar Pahlevan, Against All Logic\n'
                          'Mixes: Nicolas Jaar, Against All Logic, Ancient Astronaut\n\n'
                          'www.other-people.network',
                          style: TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                },
              ),

              const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    if (_currentChannel == null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: const Text(
          'ENTER A CHANNEL NUMBER',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'monospace',
            fontSize: 14,
            letterSpacing: 4,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      child: Column(
        children: [
          // "YOU ARE NOW LISTENING TO"
          const Text(
            'YOU ARE NOW LISTENING TO',
            style: TextStyle(
              color: Colors.white54,
              fontFamily: 'monospace',
              fontSize: 10,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),

          // Channel number ticker
          _buildTickerText(
            '${_currentChannel!.number} ',
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: 8,
            ),
          ),
          const SizedBox(height: 4),

          // Artist ticker
          _buildTickerText(
            '${_currentChannel!.artist.toUpperCase()} ',
            style: const TextStyle(
              color: Colors.white70,
              fontFamily: 'monospace',
              fontSize: 12,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 4),

          // Name ticker
          _buildTickerText(
            '${_currentChannel!.name.toUpperCase()} ',
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 14,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTickerText(String text, {required TextStyle style}) {
    // Repeat text to create ticker effect
    final repeated = text * 10;

    return SizedBox(
      height: style.fontSize! * 1.5,
      child: AnimatedBuilder(
        animation: _tickerController,
        builder: (context, child) {
          return ClipRect(
            child: Transform.translate(
              offset: Offset(-_tickerController.value * 200, 0),
              child: Text(
                repeated,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMainContent(bool isOffline) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Artwork and input row
          Expanded(
            flex: 2,
            child: Row(
              children: [
                // Left: Artwork
                Expanded(
                  child: _buildArtwork(),
                ),
                const SizedBox(width: 16),
                // Right: Input section
                Expanded(
                  child: _buildInputSection(isOffline),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Channel list
          Expanded(
            flex: 3,
            child: _buildChannelList(isOffline),
          ),
        ],
      ),
    );
  }

  Widget _buildArtwork() {
    // Try local image first, then network
    final localImagePath = _currentChannel != null
        ? _downloadService.getLocalImagePath(_currentChannel!.number)
        : null;

    if (localImagePath != null) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
        ),
        child: Image.file(
          File(localImagePath),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildPlaceholderArt(),
        ),
      );
    }

    if (_currentChannel?.imageUrl != null) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
        ),
        child: Image.network(
          _currentChannel!.imageUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildPlaceholderArt(),
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return _buildPlaceholderArt(isLoading: true);
          },
        ),
      );
    }
    return _buildPlaceholderArt();
  }

  Widget _buildPlaceholderArt({bool isLoading = false}) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        color: Colors.white10,
      ),
      child: Center(
        child: isLoading
            ? const CircularProgressIndicator(
                color: Colors.white24,
                strokeWidth: 2,
              )
            : Text(
                _currentChannel?.name.substring(0, 1).toUpperCase() ?? '?',
                style: const TextStyle(
                  color: Colors.white24,
                  fontFamily: 'monospace',
                  fontSize: 64,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  Widget _buildInputSection(bool isOffline) {
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isOffline ? 'Offline Mode' : 'Enter a number',
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isOffline
                ? '${_downloadService.downloadedCount} channels saved'
                : 'Between 0-333',
            style: const TextStyle(
              color: Colors.white54,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 12),

          // Number input (disabled in offline mode without downloads)
          if (!isOffline) ...[
            SizedBox(
              height: 44,
              child: TextField(
              controller: _channelController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 24,
                letterSpacing: 4,
              ),
              decoration: InputDecoration(
                hintText: '___',
                hintStyle: const TextStyle(
                  color: Colors.white24,
                  fontFamily: 'monospace',
                  fontSize: 24,
                  letterSpacing: 4,
                ),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(0),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(0),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(0),
                  borderSide: const BorderSide(color: Colors.white),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              onSubmitted: (_) => _onSubmitChannel(),
            ),
          ),
          const SizedBox(height: 8),

          // Tune button
          SizedBox(
            width: double.infinity,
            height: 36,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _onSubmitChannel,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(0),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Text(
                      'TUNE IN',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        letterSpacing: 4,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],

        // Error message
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            style: const TextStyle(
              color: Colors.red,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
        ],

        // Playing indicator
        if (_isPlaying) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'NOW PLAYING',
                style: TextStyle(
                  color: Colors.green,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  letterSpacing: 2,
                ),
              ),
              // Show if playing from local
              if (_currentChannel != null &&
                  _downloadService.isChannelDownloaded(_currentChannel!.number)) ...[
                const SizedBox(width: 8),
                const Icon(Icons.download_done, color: Colors.green, size: 12),
              ],
            ],
          ),
        ],
        ],
      ),
    );
  }

  Widget _buildChannelList(bool isOffline) {
    // In offline mode, only show downloaded channels
    final channels = isOffline ? _downloadService.downloadedChannels : sortedChannels;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.white10,
            width: double.infinity,
            child: Row(
              children: [
                Text(
                  isOffline ? 'SAVED CHANNELS' : 'ALL CHANNELS',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontFamily: 'monospace',
                    fontSize: 10,
                    letterSpacing: 2,
                  ),
                ),
                const Spacer(),
                Text(
                  '${channels.length}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          // Channel list
          Expanded(
            child: channels.isEmpty
                ? const Center(
                    child: Text(
                      'No channels saved yet.\nPlay a channel with "Save for Offline" enabled.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white38,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final channel = channels[index];
                      final isSelected = _currentChannel?.number == channel.number;
                      final isDownloaded = _downloadService.isChannelDownloaded(channel.number);
                      final isDownloading = _downloadService.isChannelDownloading(channel.number);
                      final progress = _downloadService.getDownloadProgress(channel.number);

                      return InkWell(
                        onTap: () => _tuneToChannel(channel.number),
                        onLongPress: isDownloaded
                            ? () => _showChannelOptions(channel)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white10 : Colors.transparent,
                            border: Border(
                              bottom: BorderSide(
                                color: Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              // Channel number
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '${channel.number}'.padLeft(3, '0'),
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : Colors.white54,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Channel name
                              Expanded(
                                child: Text(
                                  channel.name.toUpperCase(),
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : Colors.white70,
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    letterSpacing: 1,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Download indicator
                              if (isDownloading)
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    value: progress > 0 ? progress : null,
                                    strokeWidth: 2,
                                    color: Colors.white54,
                                  ),
                                )
                              else if (isDownloaded)
                                const Icon(
                                  Icons.download_done,
                                  color: Colors.green,
                                  size: 14,
                                ),
                              // Playing indicator
                              if (isSelected && _isPlaying) ...[
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.graphic_eq,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showChannelOptions(NetworkChannel channel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text(
                'Delete "${channel.name}"',
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Remove from offline storage',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () async {
                Navigator.pop(context);
                await _downloadService.deleteChannel(channel.number);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: const Text(
        'We Share Time!',
        style: TextStyle(
          color: Colors.white38,
          fontFamily: 'monospace',
          fontSize: 12,
          letterSpacing: 2,
          fontStyle: FontStyle.italic,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
