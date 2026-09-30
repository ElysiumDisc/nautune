import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart'
    show AudioInterruptionType, AudioSession;
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../data/network_channels.dart';
import '../models/network_channel.dart';
import '../providers/connectivity_provider.dart';
import '../providers/demo_mode_provider.dart';
import '../services/audio_player_service.dart';
import '../services/network_download_service.dart';

/// Network easter egg screen - mimics other-people.network radio interface.
/// Online-only feature for streaming radio shows from Nicolas Jaar's Other People label.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final TextEditingController _channelController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  NetworkChannel? _currentChannel;
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _isLoading = false;
  String? _errorMessage;

  /// The tuned channel's recording is gone from the server (and not saved on
  /// this device): the dial shows "signal lost" instead of playing.
  bool _signalLost = false;

  // iOS interruptions (calls, Siri, alarms) and route loss. audioplayers
  // doesn't observe them itself, so the radio would go silent while the UI
  // still says it is playing.
  final List<StreamSubscription<Object?>> _sessionSubs = [];
  bool _resumeAfterInterruption = false;

  // Download service (app-wide singleton, so downloads outlive this screen)
  final NetworkDownloadService _downloadService =
      NetworkDownloadService.instance;

  // Cached storage stats for the downloads sheet; refreshed when the
  // downloaded count changes instead of re-statting every file per build.
  Future<NetworkStorageStats>? _statsFuture;
  int _statsForCount = -1;

  // Main music player. The radio plays on its own AVPlayer, so the music is
  // paused while tuned in (and resumed on exit if we paused it).
  late final AudioPlayerService _mainPlayer;
  StreamSubscription<bool>? _mainPlayingSub;
  bool _pausedMainPlayer = false;

  // Incremented per tune request; stale requests stop touching state.
  int _tuneRequest = 0;

  final List<StreamSubscription<Object?>> _playerSubs = [];

  // Listening time tracking
  DateTime? _playStartTime;

  // Ticker animation for scrolling text (runs only while a channel plays)
  late AnimationController _tickerController;
  final Map<String, double> _tickerWidths = {};

  @override
  void initState() {
    super.initState();
    _mainPlayer = context.read<NautuneAppState>().audioService;

    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    WidgetsBinding.instance.addObserver(this);

    // Listen to player state changes
    _playerSubs.add(_audioPlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      final wasPlaying = _isPlaying;
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });

      // Track listening time
      if (_isPlaying && !wasPlaying) {
        _playStartTime = DateTime.now();
      } else if (!_isPlaying && wasPlaying) {
        _recordListenTime();
      }
      _syncTicker();
    }));

    // Listen for errors (only log actual errors, not spam)
    _playerSubs.add(_audioPlayer.onLog.listen((msg) {
      if (!msg.contains('Could not query')) {
        debugPrint('AudioPlayer: $msg');
      }
    }));

    // If the music starts (mini player, lock screen, CarPlay) while the radio
    // plays, pause the radio so the two never play on top of each other.
    _mainPlayingSub = _mainPlayer.playingStream.listen((playing) {
      if (!playing || !mounted) return;
      _pausedMainPlayer = false;
      if (_isPlaying) unawaited(_audioPlayer.pause());
    });

    // Listen to download service changes
    _downloadService.addListener(_onDownloadServiceChanged);

    // The app's Wi-Fi-only download setting applies to channel downloads
    // too; the service asks before each channel (downloads outlive this
    // screen, and the app's DownloadService lives as long as the app).
    final appDownloads = context.read<NautuneAppState>().downloadService;
    _downloadService.transferAllowed = () async =>
        !(appDownloads.wifiOnlyDownloads && await appDownloads.isOnCellular());

    unawaited(_listenToAudioSession());
  }

  Future<void> _listenToAudioSession() async {
    try {
      final session = await AudioSession.instance;
      if (!mounted) return;
      _sessionSubs.add(session.interruptionEventStream.listen((event) {
        if (!mounted) return;
        if (event.begin) {
          _resumeAfterInterruption = _isPlaying;
          if (_isPlaying) unawaited(_audioPlayer.pause());
        } else {
          final resume = _resumeAfterInterruption &&
              event.type == AudioInterruptionType.pause &&
              !_mainPlayer.isPlaying;
          _resumeAfterInterruption = false;
          if (resume) unawaited(_audioPlayer.resume());
        }
      }));
      // Headphones unplugged: don't carry on out of the speaker.
      _sessionSubs.add(session.becomingNoisyEventStream.listen((_) {
        if (mounted && _isPlaying) unawaited(_audioPlayer.pause());
      }));
    } catch (e) {
      debugPrint('Network radio: audio session unavailable: $e');
    }
  }

  void _onDownloadServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Record any remaining listen time before disposing
    _recordListenTime();
    _tuneRequest++;
    _tickerController.dispose();
    for (final sub in _playerSubs) {
      sub.cancel();
    }
    for (final sub in _sessionSubs) {
      sub.cancel();
    }
    _mainPlayingSub?.cancel();
    _audioPlayer.dispose();
    if (_pausedMainPlayer && !_mainPlayer.isPlaying) {
      unawaited(_mainPlayer.resume());
    }
    _channelController.dispose();
    _scrollController.dispose();
    _downloadService.removeListener(_onDownloadServiceChanged);
    super.dispose();
  }

  /// The ticker scrolls only while the radio plays; a paused or finished
  /// channel keeps its text still instead of redrawing every frame.
  void _syncTicker() {
    if (_currentChannel != null && _isPlaying) {
      if (!_tickerController.isAnimating) _tickerController.repeat();
    } else if (_tickerController.isAnimating) {
      _tickerController.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        // Muted radio in the background would only burn data and battery.
        if (_isMuted && _isPlaying) unawaited(_audioPlayer.pause());
        if (_tickerController.isAnimating) _tickerController.stop();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (_tickerController.isAnimating) _tickerController.stop();
        break;
      case AppLifecycleState.resumed:
        if (mounted) _syncTicker();
        break;
      case AppLifecycleState.detached:
        break;
    }
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

  /// Tune to a typed channel number: an exact channel if one exists,
  /// otherwise the nearest one in the 0-333 dial range.
  Future<void> _tuneToNumber(int channelNumber) {
    final channel = networkChannelsByNumber[channelNumber] ??
        findNearestChannel(channelNumber.clamp(0, 333));
    return _tuneToChannel(channel);
  }

  /// No network, or the user chose "Go offline" (nothing is streamed then).
  bool _offlineNow() =>
      !context.read<ConnectivityProvider>().networkAvailable ||
      context.read<NautuneAppState>().isOfflineMode;

  Future<void> _tuneToChannel(NetworkChannel channel) async {
    // Record listening time for previous channel before switching
    _recordListenTime();

    final isDownloaded = _downloadService.isChannelDownloaded(channel.number);

    // The recording is gone from the server: the dial lands on dead air.
    if (!channel.available && !isDownloaded) {
      ++_tuneRequest;
      unawaited(_audioPlayer.stop());
      setState(() {
        _currentChannel = channel;
        _signalLost = true;
        _isLoading = false;
        _errorMessage = null;
      });
      _syncTicker();
      return;
    }

    // Offline guard: if we're offline and this channel isn't downloaded,
    // surface a clear message instead of silently failing the stream attempt.
    final isOffline = _offlineNow();
    if (isOffline && !isDownloaded) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Offline — channel ${channel.number} not downloaded. Download it while online to play offline.',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final request = ++_tuneRequest;
    bool stale() => !mounted || request != _tuneRequest;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Pause the music so radio and library don't play on top of each other.
      if (_mainPlayer.isPlaying) {
        _pausedMainPlayer = true;
        await _mainPlayer.pause();
        if (stale()) return;
      }

      await _audioPlayer.stop();
      if (stale()) return;

      // Get playback URL (local if downloaded, stream otherwise)
      final playbackUrl = await _downloadService.getPlaybackUrl(channel);
      if (stale()) return;
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
      if (stale()) return;

      await _audioPlayer.setVolume(_isMuted ? 0.0 : 1.0);
      if (stale()) return;
      await _audioPlayer.resume();
      if (stale()) return;

      setState(() {
        _currentChannel = channel;
        _signalLost = false;
        _isLoading = false;
      });
      _syncTicker();
    } catch (e) {
      debugPrint('Network radio error: $e');
      if (stale()) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to tune to channel ${channel.number}';
      });
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _audioPlayer.setVolume(_isMuted ? 0.0 : 1.0);
  }

  /// Pause or resume the tuned channel (resuming pauses the music again).
  Future<void> _togglePlayPause() async {
    if (_currentChannel == null || _signalLost || _isLoading) return;
    if (_isPlaying) {
      await _audioPlayer.pause();
      return;
    }
    if (_mainPlayer.isPlaying) {
      _pausedMainPlayer = true;
      await _mainPlayer.pause();
    }
    if (!mounted) return;
    await _audioPlayer.resume();
  }

  /// Why a download can't start right now, or null if it can.
  Future<String?> _downloadBlockedReason() async {
    if (_offlineNow()) return 'Offline — connect to download channels.';
    final allowed = _downloadService.transferAllowed;
    if (allowed != null && !await allowed()) {
      return 'Wi-Fi-only downloads is on. Connect to Wi-Fi to download.';
    }
    return null;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _downloadOne(NetworkChannel channel) async {
    final blocked = await _downloadBlockedReason();
    if (blocked != null) return _showSnack(blocked);
    await _downloadService.downloadChannel(channel);
  }

  /// "Download All" is gigabytes: confirm with the size (and the connection
  /// type) first.
  Future<void> _confirmDownloadAll(BuildContext sheetContext) async {
    final appDownloads = context.read<NautuneAppState>().downloadService;
    final blocked = await _downloadBlockedReason();
    if (blocked != null) return _showSnack(blocked);
    if (!sheetContext.mounted) return;

    final remaining = _downloadService.remainingDownloadCount;
    final available = availableNetworkChannels.length;
    final approxGb = available == 0
        ? 0.0
        : networkAllChannelsApproxBytes * remaining / available / 1e9;
    final onCellular = await appDownloads.isOnCellular();
    if (!sheetContext.mounted) return;

    final confirm = await showDialog<bool>(
      context: sheetContext,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'Download All Channels?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '$remaining channels, about ${approxGb.toStringAsFixed(1)} GB.'
          '${onCellular ? '\n\nYou are on cellular data.' : ''}',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (confirm == true) await _downloadService.downloadAllChannels();
  }

  void _onSubmitChannel() {
    final text = _channelController.text.trim();
    if (text.isEmpty) return;

    final number = int.tryParse(text);
    if (number != null) {
      _tuneToNumber(number);
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
      // Rebuild the sheet whenever download state changes (progress, counts).
      builder: (context) => ListenableBuilder(
        listenable: _downloadService,
        builder: (context, _) => _buildSettingsSheet(),
      ),
    );
  }

  Future<NetworkStorageStats> _storageStats() {
    final count = _downloadService.downloadedCount;
    if (_statsFuture == null || _statsForCount != count) {
      _statsForCount = count;
      _statsFuture = _downloadService.getStorageStats();
    }
    return _statsFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final connectivity = context.watch<ConnectivityProvider>();
    final demoMode = context.watch<DemoModeProvider>();
    final userOffline =
        context.select<NautuneAppState, bool>((s) => s.isOfflineMode);
    final isOffline =
        !connectivity.networkAvailable || userOffline || demoMode.isDemoMode;
    final hasDownloads = _downloadService.downloadedCount > 0;
    // Mute the ticker animation when this screen isn't the topmost route, so
    // the controller doesn't keep spending frames while another screen covers it.
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;

    // Show offline/demo message only if no downloads available
    if (isOffline && !hasDownloads) {
      final message = demoMode.isDemoMode
          ? 'DEMO MODE\n\nDownload channels while online\nto access them in demo mode'
          : 'THE NETWORK REQUIRES\nAN INTERNET CONNECTION\n\nDownload channels while online\nto access them offline';
      return TickerMode(
        enabled: routeIsCurrent,
        child: Scaffold(
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
        ),
      );
    }

    return TickerMode(
      enabled: routeIsCurrent,
      child: Scaffold(
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
                    '${availableNetworkChannels.length - _downloadService.remainingDownloadCount}'
                    '/${availableNetworkChannels.length}',
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
    return Builder(
      builder: (context) {
        // Calculate download progress. Channels whose recording is gone from
        // the server can't be downloaded, so they don't count.
        final totalChannels = availableNetworkChannels.length;
        final downloadedCount =
            totalChannels - _downloadService.remainingDownloadCount;
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
                    ] else if (_downloadService.stoppedByPolicy) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Stopped: Wi-Fi-only downloads is on.',
                        style: TextStyle(
                          color: Colors.amber,
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
                                // The sheet and screen listen to the
                                // service, so no manual refresh.
                                : () => _confirmDownloadAll(context),
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
                future: _storageStats(),
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
          // "YOU ARE NOW LISTENING TO" (or dead air on a lost channel)
          Text(
            _signalLost ? 'SIGNAL LOST' : 'YOU ARE NOW LISTENING TO',
            style: TextStyle(
              color: _signalLost ? Colors.redAccent : Colors.white54,
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
            _signalLost
                ? 'THIS TRANSMISSION HAS ENDED '
                : '${_currentChannel!.artist.toUpperCase()} ',
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
    // Repeat text to create ticker effect. Scroll by exactly one repetition
    // per cycle so the wrap from 1.0 back to 0.0 is seamless (no jump).
    final repeated = text * 10;
    final textScaler = MediaQuery.textScalerOf(context);
    // Measured once per text/size: the screen rebuilds on every download
    // progress tick, and three layouts per rebuild add up.
    final key = '$text|${style.fontSize}|${style.letterSpacing}|'
        '${textScaler.scale(style.fontSize!)}';
    final unitWidth = _tickerWidths[key] ??= () {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }();

    return SizedBox(
      height: style.fontSize! * 1.5,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _tickerController,
          builder: (context, child) => Transform.translate(
            offset: Offset(-_tickerController.value * unitWidth, 0),
            child: child,
          ),
          child: Text(
            repeated,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
            textScaler: textScaler,
          ),
        ),
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
        child: CachedNetworkImage(
          imageUrl: _currentChannel!.imageUrl!,
          fit: BoxFit.cover,
          errorWidget: (context, url, error) => _buildPlaceholderArt(),
          placeholder: (context, url) => _buildPlaceholderArt(isLoading: true),
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

        // Pause / resume the tuned channel
        if (_currentChannel != null && !_signalLost) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 36,
            child: OutlinedButton.icon(
              onPressed: _isLoading ? null : _togglePlayPause,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
                shape: const RoundedRectangleBorder(),
              ),
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 18),
              label: Text(
                _isPlaying ? 'PAUSE' : 'PLAY',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
                      'No channels saved yet.\nDownload channels while online.',
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
                        onTap: () => _tuneToChannel(channel),
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
                                    color: isSelected
                                        ? Colors.white
                                        : (channel.available || isDownloaded)
                                            ? Colors.white70
                                            : Colors.white30,
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
                                )
                              else if (!channel.available)
                                // Recording gone from the server.
                                const Icon(
                                  Icons.signal_cellular_off,
                                  color: Colors.white24,
                                  size: 14,
                                )
                              else if (!isOffline)
                                // Download just this channel.
                                InkResponse(
                                  onTap: () => _downloadOne(channel),
                                  radius: 18,
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4),
                                    child: Icon(
                                      Icons.download_outlined,
                                      color: Colors.white38,
                                      size: 16,
                                    ),
                                  ),
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
